local ContextExtractor = require("koassistant_context_extractor")
local ScopeResolver = require("koassistant_scope_resolver")
local logger = require("koassistant_logger")

local BookTools = {}
BookTools.__index = BookTools

-- Case folding for matching: KOReader's utf8proc (NFKC case fold: Cyrillic, Greek and
-- accented Latin fold like ASCII, full-width Latin and ligatures fold to their plain
-- forms) when it loads, string.lower otherwise (unit tests). ASCII-only text takes the
-- cheap path. Every comparison goes through this one function, so query and text agree.
local lowercase = string.lower
do
    local ok, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok and type(Utf8Proc) == "table" and type(Utf8Proc.lowercase) == "function" then
        lowercase = function(text)
            -- Lead bytes C3-E1 and E3-F4 start non-ASCII letters (accented Latin, Greek,
            -- Cyrillic, Arabic, CJK...); C2 and E2 start the punctuation English text is
            -- full of (no-break space, curly quotes, dashes, ellipsis), which has no case.
            if not text:find("[\195-\225\227-\244]") then return text:lower() end
            local folded_ok, folded = pcall(Utf8Proc.lowercase, text, true)
            if folded_ok and type(folded) == "string" then return folded end
            return text:lower()
        end
    end
end

local MAX_READ_PAGES = 5
local MAX_READ_CHARS = 8000
local MAX_READ_TARGETS = 4
local MAX_SNIPPET_CHARS = 1200
local MAX_SEARCH_EXCERPT_CHARS = 180
local SEARCH_CONTEXT_WORDS = 5
local DEFAULT_TOC_SNIPPET_CHARS = 0
local MAX_TOC_SNIPPET_CHARS = 800
local MAX_TOC_ENTRIES = 120
local MAX_SENTENCE_CHUNK = 700
-- search_book result caps (tools audit 2026-09-10, tool_based_context_plan.md section 9):
-- a hit is ~70 tokens as JSON and every round re-sends earlier results, so the JSON the
-- model sees is capped here, not only in the phase-2 bundle. Exact totals always ride along.
local DEFAULT_MAX_HITS = 12
local MAX_HITS_CEILING = 40
local MAX_HITS_PER_PAGE = 2      -- phrase hits tie on score, so a plain top-N is "the first N pages"
local MAX_PAGE_SUMMARY = 40
local LITERAL_CONTEXT_BYTES = 70
local MAX_TOC_PATH_DEPTH = 16
local PARTIAL_MIN_TOKENS = 3      -- partial coverage needs a query of at least this many words
local PARTIAL_COVERAGE = 0.6      -- ... and this share of them in the sentence (3 -> 2, 5 -> 3)
local OUTLINE_MAX_ENTRIES = 40    -- contents outline sent with the tool scope on round one

-- Notes are the sentences the model actually reads. Every cap, clamp or exclusion a result
-- applies is stated here in prose: a boolean flag gets skipped, a sentence does not. The
-- runner prints them at the top of each bundle section too, so phase 2 inherits them.
local function addNote(result, text)
    result.notes = result.notes or {}
    table.insert(result.notes, text)
end

local function clamp(value, min_value, max_value)
    value = tonumber(value) or min_value
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function trim(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Whitespace to single spaces; the no-break space counts as whitespace so tokens split
-- on it like on a plain space (EPUBs use it inside names and numbers).
local function squeeze(text)
    return trim((text or ""):gsub("\194\160", " "):gsub("%s+", " "))
end

local function excerpt(text, max_chars)
    text = squeeze(text)
    max_chars = max_chars or MAX_SNIPPET_CHARS
    if #text <= max_chars then return text end
    return trim(ScopeResolver.utf8Head(text, max_chars - 3)) .. "..."
end

local function normalizeText(text, case_sensitive)
    text = squeeze(text)
    if not case_sensitive then
        text = lowercase(text)
    end
    return text
end

-- Punctuation stripped from token edges: ASCII (%p) plus common non-ASCII marks. Interior
-- punctuation stays (don't, self-knowledge, 1,000), so a token is what a reader would
-- call a word in any space-separated script (Arabic, Cyrillic, Greek, accented Latin get
-- the same rungs as English). CJK text has no spaces, so a clause stays one token and
-- matches by substring; character bigrams are the later step.
local EDGE_PUNCT = {
    "\226\128\156", "\226\128\157", "\226\128\152", "\226\128\153",   -- “ ” ‘ ’
    "\194\171", "\194\187", "\226\128\185", "\226\128\186",           -- « » ‹ ›
    "\226\128\158", "\226\128\154", "\226\128\148", "\226\128\147",   -- „ ‚ — –
    "\226\128\166", "\194\191", "\194\161", "\194\183", "\226\128\162", -- … ¿ ¡ · •
    "\227\128\129", "\227\128\130", "\239\188\140", "\239\188\155",   -- 、 。 ， ；
    "\239\188\154", "\239\188\159", "\239\188\129", "\239\188\136", "\239\188\137", -- ： ？ ！ （ ）
    "\227\128\140", "\227\128\141", "\227\128\142", "\227\128\143",   -- 「 」 『 』
    "\227\128\144", "\227\128\145", "\227\128\138", "\227\128\139",   -- 【 】 《 》
    "\216\140", "\216\155", "\216\159", "\219\148", "\224\165\164",   -- ، ؛ ؟ ۔ ।
}

local EDGE_PUNCT_SET = {}
for _idx, mark in ipairs(EDGE_PUNCT) do EDGE_PUNCT_SET[mark] = true end

local function isWordByte(b)
    return b and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- Strip edge punctuation. Fast path: a chunk that starts and ends with an ASCII letter or
-- digit is already a token (most English chunks); the tokenizer runs over every sentence
-- of a book, so this is the hot loop.
local function stripEdges(token)
    if isWordByte(token:byte(1)) and isWordByte(token:byte(-1)) then return token end
    token = token:match("^%p*(.-)%p*$") or ""
    if token:find("[\128-\255]") then
        local changed = true
        while changed and token ~= "" do
            changed = false
            -- Non-ASCII marks are 2 or 3 bytes: four lookups instead of a scan of the list.
            for n = 2, 3 do
                if #token >= n and EDGE_PUNCT_SET[token:sub(1, n)] then
                    token = token:sub(n + 1)
                    changed = true
                end
                if #token >= n and EDGE_PUNCT_SET[token:sub(-n)] then
                    token = token:sub(1, -n - 1)
                    changed = true
                end
            end
            if changed then
                token = token:match("^%p*(.-)%p*$") or ""
            end
        end
    end
    return token
end

local function tokenize(text, case_sensitive)
    text = text or ""
    if not case_sensitive then
        text = lowercase(text)
    end
    local tokens = {}
    local seen = {}
    -- Sentences arrive squeezed (no-break spaces already spaces); queries are squeezed
    -- by collectQueries. No per-call pass here: this runs over every sentence of a book.
    for chunk in text:gmatch("%S+") do
        local token = stripEdges(chunk)
        if token ~= "" and not seen[token] then
            seen[token] = true
            table.insert(tokens, token)
        end
    end
    return tokens
end

local function cleanWord(word, case_sensitive)
    word = stripEdges(tostring(word or ""))
    if not case_sensitive then
        word = lowercase(word)
    end
    return word
end

local function splitWords(text)
    local words = {}
    for word in tostring(text or ""):gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

-- Sentence terminators outside ASCII: CJK full stop / exclamation / question marks, the
-- Arabic question mark and the Devanagari danda. Each is tagged with \1 so the ASCII
-- splitter below sees one class; the tag is dropped when the sentence is squeezed.
local SENTENCE_ENDS = {
    "\227\128\130", "\239\188\129", "\239\188\159",   -- 。 ！ ？
    "\216\159", "\224\165\164",                       -- ؟ ।
}

local function splitSentences(text)
    text = (text or ""):gsub("[\r\n]+", ". ")
    if text:find("[\128-\255]") then
        for _idx, mark in ipairs(SENTENCE_ENDS) do
            text = text:gsub(mark, mark .. "\1")
        end
    end
    local sentences = {}
    for sentence in text:gmatch("[^%.%!%?\1]+[%.%!%?\1]?") do
        local current = squeeze((sentence:gsub("\1", "")))
        if current ~= "" then
            while #current > MAX_SENTENCE_CHUNK do
                local cut = current:sub(1, MAX_SENTENCE_CHUNK):match("^(.+)%s+%S*$")
                    or ScopeResolver.utf8Head(current, MAX_SENTENCE_CHUNK)
                table.insert(sentences, trim(cut))
                current = trim(current:sub(#cut + 1))
            end
            if current ~= "" then
                table.insert(sentences, current)
            end
        end
    end
    return sentences
end

local function levenshteinWithin(a, b, max_distance)
    if a == b then return true end
    local la, lb = #a, #b
    if math.abs(la - lb) > max_distance then return false end
    if la == 0 or lb == 0 then return math.max(la, lb) <= max_distance end

    local prev = {}
    local curr = {}
    for j = 0, lb do prev[j] = j end

    for i = 1, la do
        curr[0] = i
        local row_min = curr[0]
        local ca = a:sub(i, i)
        for j = 1, lb do
            local cost = ca == b:sub(j, j) and 0 or 1
            local deletion = prev[j] + 1
            local insertion = curr[j - 1] + 1
            local substitution = prev[j - 1] + cost
            local value = math.min(deletion, insertion, substitution)
            curr[j] = value
            if value < row_min then row_min = value end
        end
        if row_min > max_distance then return false end
        prev, curr = curr, prev
    end

    return prev[lb] <= max_distance
end

-- Edit-distance allowance for a query word. ASCII only: the distance counts bytes, and a
-- byte edit inside a multi-byte character is not a typo, so non-ASCII words match exactly.
local function tokenThreshold(token)
    local len = #token
    if len <= 3 or token:find("[\128-\255]") then return 0 end
    return math.max(1, math.floor(len * 0.25))
end

local function isAsciiWordByte(b)
    return b ~= nil and ((b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122))
end

-- First occurrence of needle in haystack that is not glued to an ASCII letter or digit on
-- either side ("anima" inside "animals" does not count). A non-ASCII neighbour counts as a
-- boundary: Arabic clitics and CJK text run words together. nil when every occurrence is
-- inside a longer word.
local function findBounded(haystack, needle)
    local from = 1
    while true do
        local s, e = haystack:find(needle, from, true)
        if not s then return nil end
        if not isAsciiWordByte(haystack:byte(s - 1)) and not isAsciiWordByte(haystack:byte(e + 1)) then
            return s
        end
        from = s + 1
    end
end

local function allTokensPresent(tokens, haystack)
    for _, token in ipairs(tokens) do
        if not haystack:find(token, 1, true) then
            return false
        end
    end
    return true
end

-- Count the query tokens present in a sentence: as substrings of the normalized text,
-- or (fuzzy on) within edit distance of one of its tokens. Stops as soon as the remaining
-- tokens can no longer reach `need`. Returns the count and the tokens not found.
local function countTokenMatches(tokens, haystack, sentence_tokens_fn, fuzzy, need)
    local matched, missing = 0, {}
    local sentence_tokens
    for i, query_token in ipairs(tokens) do
        local found = haystack:find(query_token, 1, true) ~= nil
        if not found and fuzzy then
            local threshold = tokenThreshold(query_token)
            if threshold > 0 then
                sentence_tokens = sentence_tokens or sentence_tokens_fn()
                for _, sentence_token in ipairs(sentence_tokens) do
                    if levenshteinWithin(query_token, sentence_token, threshold) then
                        found = true
                        break
                    end
                end
            end
        end
        if found then
            matched = matched + 1
        else
            table.insert(missing, query_token)
        end
        if matched + (#tokens - i) < need then break end
    end
    return matched, missing
end

-- Partial coverage: a sentence holding most of a longer query's words still counts,
-- below every all-words rung. "family mother kinship" then finds a sentence with two
-- of the three instead of nothing.
local function partialNeed(token_count)
    return math.ceil(token_count * PARTIAL_COVERAGE)
end

local function safeCall(fn)
    local ok, result = pcall(fn)
    if ok then return result end
    return nil
end

local function wordMatches(word, query_tokens, fuzzy, case_sensitive)
    local cleaned = cleanWord(word, case_sensitive)
    if cleaned == "" then return false end
    for _, token in ipairs(query_tokens or {}) do
        if cleaned == token then
            return true
        end
        if fuzzy then
            local threshold = tokenThreshold(token)
            if threshold > 0 and levenshteinWithin(token, cleaned, threshold) then
                return true
            end
        end
    end
    return false
end

local function concordanceExcerpt(sentence, query_tokens, fuzzy, case_sensitive)
    local words = splitWords(sentence)
    if #words == 0 then return "" end

    local match_index = nil
    for i, word in ipairs(words) do
        if wordMatches(word, query_tokens, fuzzy, case_sensitive) then
            match_index = i
            break
        end
    end
    match_index = match_index or 1

    local start_index = math.max(1, match_index - SEARCH_CONTEXT_WORDS)
    local end_index = math.min(#words, match_index + SEARCH_CONTEXT_WORDS)
    local excerpt_text = table.concat(words, " ", start_index, end_index)
    if start_index > 1 then
        excerpt_text = "..." .. excerpt_text
    end
    if end_index < #words then
        excerpt_text = excerpt_text .. "..."
    end
    return excerpt(excerpt_text, MAX_SEARCH_EXCERPT_CHARS)
end

-- Excerpt around a literal (token-less) match: a byte window either side of the match,
-- trimmed to character boundaries. Used when the query has no word tokens (CJK text).
local function literalExcerpt(sentence, position, match_len)
    local from = math.max(1, position - LITERAL_CONTEXT_BYTES)
    local to = math.min(#sentence, position + match_len - 1 + LITERAL_CONTEXT_BYTES)
    local text = sentence:sub(from, to)
    if from > 1 then text = ScopeResolver.utf8TrimHead(text) end
    if to < #sentence then text = ScopeResolver.utf8TrimTail(text) end
    if from > 1 then text = "..." .. text end
    if to < #sentence then text = text .. "..." end
    return text
end

-- Pick the hits the model sees: best score first, at most MAX_HITS_PER_PAGE per page so a
-- common name does not fill the list with one page's occurrences; skipped hits fill the
-- remainder when there are not enough pages.
local function selectHits(scored, max_hits)
    local selected, per_page, skipped = {}, {}, {}
    for _idx, hit in ipairs(scored) do
        if #selected >= max_hits then break end
        local n = per_page[hit.page] or 0
        if n < MAX_HITS_PER_PAGE then
            per_page[hit.page] = n + 1
            table.insert(selected, hit)
        else
            table.insert(skipped, hit)
        end
    end
    for _idx, hit in ipairs(skipped) do
        if #selected >= max_hits then break end
        table.insert(selected, hit)
    end
    table.sort(selected, function(a, b)
        if a.score == b.score then return a.page < b.page end
        return a.score > b.score
    end)
    return selected
end

function BookTools:new(ui, settings)
    local instance = setmetatable({}, self)
    instance.ui = ui
    instance.settings = settings or {}
    -- "current" = clamp all reads/searches to the current reading position (spoiler-safe);
    -- "full" = the whole document is readable (research/non-fiction/finished books).
    instance.reading_scope = instance.settings.reading_scope or "current"
    instance.extractor = ContextExtractor:new(ui, instance.settings)
    instance.sentence_cache = {}   -- page -> sentences (split once, reused by every query)
    instance.token_cache = {}      -- "ci"/"cs" -> page -> sentence index -> tokens
    instance.norm_cache = {}       -- "ci"/"cs" -> page -> sentence index -> normalized text
    instance.page_index = nil      -- built by indexPages on the first indexed query
    instance.use_index = instance.settings.search_index ~= false  -- false = brute-force scan (parity tests)
    instance.last_hits = {}
    return instance
end

function BookTools:getTotalPages()
    local document = self.ui and self.ui.document
    return document and document.info and document.info.number_of_pages or 0
end

function BookTools:getCurrentPage()
    local document = self.ui and self.ui.document
    if not document then return nil end

    local page = self.ui.view and self.ui.view.state and self.ui.view.state.page
    if not page and document.getXPointer and document.getPageFromXPointer then
        local xp = safeCall(function() return document:getXPointer() end)
        if xp then
            page = safeCall(function() return document:getPageFromXPointer(xp) end)
        end
    end
    page = tonumber(page)

    local total_pages = self:getTotalPages()
    if total_pages <= 0 then return page end
    if not page or page < 1 then return 1 end
    if page > total_pages then return total_pages end
    return page
end

function BookTools:isAvailable()
    return self.ui and self.ui.document and self:getTotalPages() > 0
end

--- Highest page the tools may read/search. Equals the current page under "current" scope
-- (spoiler-safe — the model cannot reach later pages) or the last page under "full" scope.
function BookTools:getReadCeiling()
    if self.reading_scope == "full" then
        local total = self:getTotalPages()
        if total > 0 then return total end
    end
    return self:getCurrentPage() or self:getTotalPages()
end

--- Note for every result while the reading ceiling hides part of the book.
function BookTools:readableRangeNote()
    local total = self:getTotalPages()
    local ceiling = self:getReadCeiling()
    if self.reading_scope ~= "full" and ceiling < total then
        return string.format("This call covers pages 1-%d of %d only (the reader's current position). "
            .. "The %d later pages are out of reach while spoiler protection is on: a missing hit is not "
            .. "evidence that the book lacks it, so say so instead of answering from memory.",
            ceiling, total, total - ceiling)
    end
end

--- Note when the reader has hidden sections (KOReader hidden flows): honored, never silent.
function BookTools:hiddenFlowsNote(what)
    local document = self.ui and self.ui.document
    if document and document.hasHiddenFlows and document:hasHiddenFlows() then
        local visible = ContextExtractor.getFlowFingerprint(document)
        local total = self:getTotalPages()
        if visible and total > visible then
            return string.format("%d of %d pages are in sections the reader has hidden (KOReader hidden "
                .. "flows) and were not %s.", total - visible, total, what)
        end
    end
end

function BookTools:getSentences(page)
    local cached = self.sentence_cache[page]
    if cached then return cached end
    local sentences = splitSentences(self:getPageText(page))
    self.sentence_cache[page] = sentences
    return sentences
end

-- The sentence as the rungs compare it (squeezed, case-folded), folded once per session:
-- the fold is the one non-trivial per-sentence cost with utf8proc in the loop.
function BookTools:getNormalizedSentence(page, index, sentence, case_sensitive)
    local key = case_sensitive and "cs" or "ci"
    local by_page = self.norm_cache[key]
    if not by_page then by_page = {}; self.norm_cache[key] = by_page end
    local per_page = by_page[page]
    if not per_page then per_page = {}; by_page[page] = per_page end
    local normalized = per_page[index]
    if not normalized then
        normalized = normalizeText(sentence, case_sensitive)
        per_page[index] = normalized
    end
    return normalized
end

function BookTools:getSentenceTokens(page, index, sentence, case_sensitive)
    local key = case_sensitive and "cs" or "ci"
    local by_page = self.token_cache[key]
    if not by_page then by_page = {}; self.token_cache[key] = by_page end
    local per_page = by_page[page]
    if not per_page then per_page = {}; by_page[page] = per_page end
    local tokens = per_page[index]
    if not tokens then
        tokens = tokenize(sentence, case_sensitive)
        per_page[index] = tokens
    end
    return tokens
end

-- Page-level inverted index, the candidate filter of docs/tool_based_context_plan.md 9.6
-- step 2: term -> pages holding it as a whole token, built lazily up to the read ceiling
-- with the same tokenizer the rungs use. A query asks the index which pages can hold
-- enough of its words and walks only those pages' sentences; the rungs and totals are
-- unchanged because a query word is [%w']+ and so can only ever match inside one token,
-- and fuzzy/substring matches are found by expanding the word over the vocabulary once.
-- Case-sensitive and token-less queries bypass it.
function BookTools:indexPages(up_to)
    local index = self.page_index
    if not index then
        index = { postings = {}, vocab = {}, built_to = 0, expansions = {} }
        self.page_index = index
    end
    if up_to <= index.built_to then return index end
    for page = index.built_to + 1, up_to do
        local seen = {}
        for _idx, sentence in ipairs(self:getSentences(page)) do
            for _t, token in ipairs(tokenize(sentence, false)) do
                if not seen[token] then
                    seen[token] = true
                    local list = index.postings[token]
                    if not list then
                        list = {}
                        index.postings[token] = list
                        table.insert(index.vocab, token)
                    end
                    table.insert(list, page)
                end
            end
        end
    end
    index.built_to = up_to
    index.expansions = {}  -- the vocabulary grew; cached expansions are stale
    return index
end

-- Vocabulary terms a query word can match: those containing it (the substring rung) and,
-- with fuzzy on, those within its edit distance. Memoized per index build.
function BookTools:expandToken(index, token, fuzzy)
    local key = (fuzzy and "f:" or "e:") .. token
    local cached = index.expansions[key]
    if cached then return cached end
    local matches = {}
    local threshold = fuzzy and tokenThreshold(token) or 0
    local token_len = #token
    for _idx, term in ipairs(index.vocab) do
        if term:find(token, 1, true) then
            table.insert(matches, term)
        elseif threshold > 0 and math.abs(#term - token_len) <= threshold
            and levenshteinWithin(token, term, threshold) then
            table.insert(matches, term)
        end
    end
    index.expansions[key] = matches
    return matches
end

-- Pages 1..up_to holding at least `need` distinct query words (a superset of the pages
-- with a sentence that does), in page order.
function BookTools:candidatePages(query_tokens, fuzzy, up_to, need)
    local index = self:indexPages(up_to)
    local counts = {}
    for _idx, token in ipairs(query_tokens) do
        local pages_seen = {}
        for _t, term in ipairs(self:expandToken(index, token, fuzzy)) do
            for _p, page in ipairs(index.postings[term]) do
                if page <= up_to and not pages_seen[page] then
                    pages_seen[page] = true
                    counts[page] = (counts[page] or 0) + 1
                end
            end
        end
    end
    local pages = {}
    for page, count in pairs(counts) do
        if count >= need then table.insert(pages, page) end
    end
    table.sort(pages)
    return pages
end

function BookTools:getScope()
    local total_pages = self:getTotalPages()
    local current_page = self:getCurrentPage() or total_pages
    return {
        start_page = 1,
        current_page = current_page,
        end_page = self:getReadCeiling(),
        total_pages = total_pages,
        reading_scope = self.reading_scope,
        outline = self:getOutline(),
    }
end

function BookTools:getPageText(page, max_chars)
    page = tonumber(page)
    if not page then return "" end
    local total_pages = self:getTotalPages()
    if total_pages <= 0 or page < 1 or page > total_pages then return "" end

    -- Not cached: the only caller is getSentences, whose sentence cache holds this text
    -- already (a whole-book session on a large book is memory-bound, plan 9.7).
    local ok, result = pcall(function()
        return self.extractor:getPageRangeText(page, page, { max_chars = max_chars or 20000 })
    end)
    local text = ok and result and result.text or ""
    if text == "" then
        self._empty_pages_logged = (self._empty_pages_logged or 0) + 1
        if self._empty_pages_logged <= 4 then
            if self._empty_pages_logged == 1 then self:logDocumentState("first empty page") end
            local document = self.ui.document
            local okx, xp = pcall(function() return document:getPageXPointer(page) end)
            local okn, xn = pcall(function() return document:getPageXPointer(page + 1) end)
            logger.dbg("BookTools diag empty page", page,
                "extract_ok", tostring(ok), "err", ok and "" or tostring(result),
                "xp", okx and tostring(xp) or ("ERR " .. tostring(xp)),
                "next_xp", okn and tostring(xn) or ("ERR " .. tostring(xn)))
        end
    end
    return text
end

function BookTools:getRangeText(start_page, end_page, max_chars)
    local current_page = self:getReadCeiling()
    if not current_page then current_page = 1 end
    start_page = clamp(start_page, 1, current_page)
    end_page = clamp(end_page, start_page, current_page)

    local result = self.extractor:getPageRangeText(start_page, end_page, {
        max_chars = max_chars or MAX_READ_CHARS,
    })
    return result and result.text or ""
end

function BookTools:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive, tokens_fn, normalized_sentence)
    normalized_sentence = normalized_sentence or normalizeText(sentence, case_sensitive)
    local normalized_query = normalizeText(query, case_sensitive)

    -- Whole-word hits outrank hits inside longer words ("anima" in "animals"): the
    -- substring rungs sit just below their whole-word twins, above fuzzy and partial.
    if normalized_sentence:find(normalized_query, 1, true) then
        if findBounded(normalized_sentence, normalized_query) then
            return 100 + math.min(#normalized_query, 40), "phrase"
        end
        return 90 + math.min(#normalized_query, 40), "substring"
    end
    local count = #query_tokens
    if allTokensPresent(query_tokens, normalized_sentence) then
        for _idx, token in ipairs(query_tokens) do
            if not findBounded(normalized_sentence, token) then
                return 60 + count, "substring"
            end
        end
        return 70 + count, "tokens"
    end
    -- Below the all-words rungs: count what is there. Fuzzy needs every word within edit
    -- distance; partial needs PARTIAL_COVERAGE of a PARTIAL_MIN_TOKENS-word query.
    local partial_ok = count >= PARTIAL_MIN_TOKENS
    local need = partial_ok and partialNeed(count) or count
    if not fuzzy and not partial_ok then
        return 0, nil
    end
    local matched, missing = countTokenMatches(query_tokens, normalized_sentence,
        tokens_fn or function() return tokenize(sentence, case_sensitive) end, fuzzy, need)
    if fuzzy and matched >= count then
        return 45 + count, "fuzzy"
    end
    if partial_ok and matched >= need then
        return 30 + matched, "partial", missing
    end
    return 0, nil
end

function BookTools:collectQueries(args)
    local queries = {}
    local seen = {}
    local function push(value)
        local cleaned = squeeze(value)  -- also folds no-break spaces, like the sentences
        if cleaned == "" then return end
        local key = lowercase(cleaned)
        if seen[key] then return end
        seen[key] = true
        table.insert(queries, cleaned)
    end
    if type(args.queries) == "table" then
        for _, q in ipairs(args.queries) do
            if type(q) == "string" then push(q) end
        end
    end
    if type(args.query) == "string" then
        push(args.query)
    end
    return queries
end

function BookTools:runQuery(query, current_page, fuzzy, case_sensitive, q_index, max_hits)
    local query_tokens = tokenize(query, case_sensitive)
    local normalized_query = normalizeText(query, case_sensitive)
    -- No word tokens (CJK and other scripts outside [%w]): match the text literally instead
    -- of failing, and say so.
    local literal = #query_tokens == 0
    if literal and normalized_query == "" then
        return {
            query = query,
            error = "query must contain searchable text",
            results = {},
            page_summary = {},
            total_hits = 0,
            matching_pages = 0,
        }
    end
    max_hits = max_hits or DEFAULT_MAX_HITS

    local scored = {}
    local page_summary = {}

    -- The pages worth walking: every page for literal or case-sensitive queries, else the
    -- index's candidates (pages that hold enough distinct query words for any rung).
    local pages
    if literal or case_sensitive or self.use_index == false then
        pages = {}
        for page = 1, current_page do pages[page] = page end
    else
        local count = #query_tokens
        local need = count >= PARTIAL_MIN_TOKENS and partialNeed(count) or count
        pages = self:candidatePages(query_tokens, fuzzy, current_page, need)
    end

    for _page_idx, page in ipairs(pages) do
        local sentences = self:getSentences(page)
        local page_hits = 0
        local first_hit_id = nil
        local last_hit_id = nil
        for index, sentence in ipairs(sentences) do
            local score, match_type, position, missing = 0, nil, nil, nil
            local normalized_sentence = self:getNormalizedSentence(page, index, sentence, case_sensitive)
            if literal then
                position = normalized_sentence:find(normalized_query, 1, true)
                if position then
                    score, match_type = 100 + math.min(#normalized_query, 40), "phrase"
                end
            else
                score, match_type, missing = self:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive,
                    function() return self:getSentenceTokens(page, index, sentence, case_sensitive) end,
                    normalized_sentence)
            end
            if score > 0 then
                local hit_id = string.format("q%d:p%d:%d", q_index, page, index)
                local hit = {
                    hit_id = hit_id,
                    page = page,
                    sentence_index = index,
                    score = score,
                    match_type = match_type,
                    missing = match_type == "partial" and missing or nil,
                    -- The literal position is in the normalized text (case folding can change
                    -- byte lengths), so the literal excerpt comes from that text.
                    snippet = literal and literalExcerpt(normalized_sentence, position, #normalized_query)
                        or concordanceExcerpt(sentence, query_tokens, fuzzy, case_sensitive),
                }
                table.insert(scored, hit)
                self.last_hits[hit_id] = hit
                page_hits = page_hits + 1
                first_hit_id = first_hit_id or hit_id
                last_hit_id = hit_id
            end
        end
        if page_hits > 0 then
            table.insert(page_summary, {
                page = page,
                count = page_hits,
                first_hit_id = first_hit_id,
                last_hit_id = last_hit_id,
            })
        end
    end

    table.sort(scored, function(a, b)
        if a.score == b.score then
            return a.page < b.page
        end
        return a.score > b.score
    end)

    local shown = selectHits(scored, max_hits)
    local summary_shown = page_summary
    if #page_summary > MAX_PAGE_SUMMARY then
        summary_shown = {}
        for i = 1, MAX_PAGE_SUMMARY do summary_shown[i] = page_summary[i] end
    end

    local block = {
        query = query,
        results = shown,
        page_summary = summary_shown,
        total_hits = #scored,
        shown_hits = #shown,
        matching_pages = #page_summary,
    }
    if literal then
        addNote(block, "This query has no word tokens (for example CJK text), so it was matched as a literal substring.")
    end
    local partial_shown = 0
    for _idx, hit in ipairs(shown) do
        if hit.match_type == "partial" then partial_shown = partial_shown + 1 end
    end
    if partial_shown > 0 then
        addNote(block, string.format("%d of the shown hits contain only some of the query words (match_type partial; the missing words are listed). Full matches rank above them.",
            partial_shown))
    end
    if #scored > #shown then
        addNote(block, string.format("Showing %d of %d hits for %q (highest scoring first, at most %d per page); total_hits is the exact count.",
            #shown, #scored, query, MAX_HITS_PER_PAGE))
    end
    if #page_summary > #summary_shown then
        addNote(block, string.format("page_summary lists the first %d of %d pages with hits.", #summary_shown, #page_summary))
    end
    return block
end

function BookTools:searchBook(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end

    local queries = self:collectQueries(args)
    if #queries == 0 then
        return { ok = false, error = "query or queries is required" }
    end

    local current_page = self:getReadCeiling()
    local fuzzy = args.fuzzy ~= false
    local case_sensitive = args.case_sensitive == true
    local max_hits = clamp(args.max_hits or DEFAULT_MAX_HITS, 1, MAX_HITS_CEILING)
    self.last_hits = {}

    local query_blocks = {}
    local total_hits = 0
    for q_index, query in ipairs(queries) do
        local block = self:runQuery(query, current_page, fuzzy, case_sensitive, q_index, max_hits)
        table.insert(query_blocks, block)
        total_hits = total_hits + (block.total_hits or 0)
    end

    local result = {
        ok = true,
        scope = { start_page = 1, end_page = current_page },
        query_count = #queries,
        total_hits = total_hits,
        result_format = "Per-query blocks in queries[]. Hit IDs are namespaced like q1:p42:3. Pass multiple search terms via queries=[...] to batch lookups; use read_around with hit_ids or pages for surrounding context.",
        queries = query_blocks,
    }
    local range_note = self:readableRangeNote()
    if range_note then addNote(result, range_note) end
    local flows_note = self:hiddenFlowsNote("searched")
    if flows_note then addNote(result, flows_note) end
    return result
end

local function parseHitIdPage(hit_id)
    if type(hit_id) ~= "string" then return nil end
    local page = hit_id:match("^p(%d+):%d+$")
    if page then return tonumber(page) end
    page = hit_id:match("^q%d+:p(%d+):%d+$")
    if page then return tonumber(page) end
    return nil
end

function BookTools:resolveReadTarget(args)
    local page = tonumber(args.page)
    if args.hit_id and self.last_hits[args.hit_id] then
        page = self.last_hits[args.hit_id].page
    elseif args.hit_id then
        page = parseHitIdPage(args.hit_id)
    end
    if not page then
        return nil, "hit_id or page is required"
    end

    local current_page = self:getReadCeiling()
    local requested_page = page
    page = clamp(page, 1, current_page)
    local before_pages = clamp(args.before_pages or 1, 0, MAX_READ_PAGES - 1)
    local after_pages = clamp(args.after_pages or 1, 0, MAX_READ_PAGES - 1)
    local start_page = math.max(1, page - before_pages)
    local end_page = math.min(current_page, page + after_pages)

    while end_page - start_page + 1 > MAX_READ_PAGES do
        if page - start_page > end_page - page then
            start_page = start_page + 1
        else
            end_page = end_page - 1
        end
    end

    local raw = self:getRangeText(start_page, end_page, MAX_READ_CHARS)
    local text = excerpt(raw, MAX_READ_CHARS)
    local result = {
        ok = true,
        hit_id = args.hit_id,
        page = page,
        range = { start_page = start_page, end_page = end_page },
        chars = #text,
        text = text,
    }
    if requested_page > current_page then
        addNote(result, string.format("Page %d is past the readable range (the reader is at page %d of %d); pages %d-%d were read instead.",
            requested_page, current_page, self:getTotalPages(), start_page, end_page))
    end
    if #raw > #text then
        addNote(result, string.format("The passage was cut to %d characters; ask for fewer pages or a narrower target for the rest.", MAX_READ_CHARS))
    end
    return result
end

function BookTools:readAround(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end

    local targets = nil
    if type(args.targets) == "table" then
        targets = args.targets
    elseif type(args.hit_ids) == "table" then
        targets = {}
        for _, hit_id in ipairs(args.hit_ids) do
            table.insert(targets, { hit_id = hit_id })
        end
    elseif type(args.pages) == "table" then
        targets = {}
        for _, page in ipairs(args.pages) do
            table.insert(targets, { page = page })
        end
    end

    if targets then
        local results = {}
        local unresolved = 0
        for i, target in ipairs(targets) do
            if i > MAX_READ_TARGETS then break end
            local merged = {}
            for key, value in pairs(args) do
                if key ~= "targets" and key ~= "hit_ids" and key ~= "pages" then
                    merged[key] = value
                end
            end
            if type(target) == "table" then
                for key, value in pairs(target) do
                    merged[key] = value
                end
            else
                merged.hit_id = target
            end
            local result = self:resolveReadTarget(merged)
            if result then
                table.insert(results, result)
            else
                unresolved = unresolved + 1
            end
        end
        if #results == 0 then
            return { ok = false, error = "no readable targets" }
        end
        local batch = {
            ok = true,
            target_count = #results,
            truncated = #targets > MAX_READ_TARGETS,
            max_targets = MAX_READ_TARGETS,
            results = results,
        }
        if #targets > MAX_READ_TARGETS then
            addNote(batch, string.format("Read %d of %d requested targets (limit %d per call); ask again for the rest.",
                #results, #targets, MAX_READ_TARGETS))
        end
        if unresolved > 0 then
            addNote(batch, string.format("%d target(s) could not be resolved (unknown hit_id or missing page) and were skipped.", unresolved))
        end
        local range_note = self:readableRangeNote()
        if range_note then addNote(batch, range_note) end
        return batch
    end

    local result, err = self:resolveReadTarget(args)
    if not result then
        return { ok = false, error = err }
    end
    local range_note = self:readableRangeNote()
    if range_note then addNote(result, range_note) end
    return result
end

function BookTools:getEffectiveToc()
    local document = self.ui and self.ui.document
    local toc = self.ui and self.ui.toc and self.ui.toc.toc
    if not toc or #toc == 0 then return nil end

    if document and document.hasHiddenFlows and document:hasHiddenFlows() then
        local filtered = {}
        local hidden = 0
        for _, entry in ipairs(toc) do
            if entry.page and document:getPageFlow(entry.page) == 0 then
                table.insert(filtered, entry)
            else
                hidden = hidden + 1
            end
        end
        return filtered, hidden
    end
    return toc, 0
end

--- Diagnostic dump of the document state the tools see (dbg, Console Debug only):
-- page counts from both sources, TOC size and a few entry pages, rendering state.
function BookTools:logDocumentState(where)
    local document = self.ui and self.ui.document
    if not document then return end
    local function try(name, ...)
        local fn = document[name]
        if type(fn) ~= "function" then return "n/a" end
        local ok, v = pcall(fn, document, ...)
        return ok and tostring(v) or ("ERR " .. tostring(v))
    end
    local toc = self:getEffectiveToc() or {}
    local rolling = self.ui.rolling
    logger.dbg("BookTools diag", where,
        "info.number_of_pages", tostring(document.info and document.info.number_of_pages),
        "getPageCount", try("getPageCount"),
        "current", tostring(self:getCurrentPage()),
        "view.state.page", tostring(self.ui.view and self.ui.view.state and self.ui.view.state.page),
        "toc entries", #toc,
        "rendering_state", tostring(rolling and rolling.rendering_state),
        "partial_rerenderings", try("getPartialRerenderingsCount"),
        "partial_enabled", try("isPartialRerenderingEnabled"),
        "rendering_hash", try("getDocumentRenderingHash"),
        "cache_file", try("hasCacheFile"), "cache_stale", try("isCacheFileStale"),
        "hidden_flows", try("hasHiddenFlows"))
    for _idx, i in ipairs({ 1, 40, 41, 42, 43, 44, 45, 46, 100, 500, #toc }) do
        local e = toc[i]
        if e then
            logger.dbg("BookTools diag toc", i, "page", tostring(e.page), "depth", tostring(e.depth),
                "title_len", #tostring(e.title or ""))
        end
    end
end

-- The book's text language: the document's metadata first, then KOReader's typography
-- language (set from the book or by the reader for hyphenation). nil when unknown.
function BookTools:getBookLanguage()
    local ui = self.ui
    local function clean(value)
        if type(value) ~= "string" then return nil end
        value = trim(value)
        if value == "" or value:lower() == "und" then return nil end
        return value
    end
    local lang = clean(ui and ui.doc_props and ui.doc_props.language)
    if not lang and ui and ui.document and ui.document.getProps then
        local ok, props = pcall(ui.document.getProps, ui.document)
        if ok and type(props) == "table" then lang = clean(props.language) end
    end
    if not lang and ui and ui.typography then
        lang = clean(ui.typography.text_lang_tag)
    end
    return lang
end

-- The TOC entries within the readable range, in document order, each with depth, page
-- range, parent path and the continues-past-position marker. Returns the items plus the
-- counts of entries left out: past the reading ceiling, in hidden flows.
function BookTools:collectTocEntries()
    local current_page = self:getReadCeiling()
    local total_pages = self:getTotalPages()
    local toc, hidden_count = self:getEffectiveToc()
    local items = {}
    local past_position = 0
    local ancestors = {}
    local deepest = 0

    if toc and #toc > 0 then
        for i, entry in ipairs(toc) do
            local start_page = tonumber(entry.page)
            local depth = entry.depth or 1
            for d = depth, MAX_TOC_PATH_DEPTH do ancestors[d] = nil end
            ancestors[depth] = entry.title or ""
            if start_page and start_page > current_page then
                past_position = past_position + 1
            elseif start_page then
                local end_page = current_page
                for j = i + 1, #toc do
                    local next_entry = toc[j]
                    if next_entry.page and (next_entry.depth or 1) <= depth then
                        end_page = math.min(current_page, next_entry.page - 1)
                        break
                    end
                end
                if end_page >= start_page then
                    local path = {}
                    for d = 1, depth - 1 do
                        if ancestors[d] then table.insert(path, ancestors[d]) end
                    end
                    local item = {
                        title = entry.title or "",
                        depth = depth,
                        start_page = start_page,
                        end_page = end_page,
                    }
                    if #path > 0 then item.path = table.concat(path, " > ") end
                    if end_page == current_page and current_page < total_pages then
                        item.continues_past_position = true
                    end
                    if depth > deepest then deepest = depth end
                    table.insert(items, item)
                end
            end
        end
    end
    return items, {
        has_toc = toc ~= nil and #toc > 0,
        past_position = past_position,
        hidden = hidden_count or 0,
        deepest = deepest,
        current_page = current_page,
        total_pages = total_pages,
    }
end

-- The deepest level whose cumulative entry count fits the cap. Level 1 is always chosen,
-- even when it overflows on its own. A 25-chapter book with deep subsections then lists
-- its chapters instead of chapters one to three with every sub-entry.
local function fitDepth(items, cap)
    local counts = {}
    local deepest = 0
    for _idx, item in ipairs(items) do
        counts[item.depth] = (counts[item.depth] or 0) + 1
        if item.depth > deepest then deepest = item.depth end
    end
    local cumulative, chosen = 0, 1
    for d = 1, deepest do
        cumulative = cumulative + (counts[d] or 0)
        if cumulative <= cap then chosen = d else break end
    end
    return chosen, deepest
end

local function keepUpToDepth(items, depth)
    local kept = {}
    for _idx, item in ipairs(items) do
        if item.depth <= depth then table.insert(kept, item) end
    end
    return kept
end

-- Contents outline for the tool scope message: the levels that fit OUTLINE_MAX_ENTRIES,
-- no snippets. Returned as data; the runner renders it.
function BookTools:getOutline()
    local items, info = self:collectTocEntries()
    if not info.has_toc then
        return { entries = {}, total = 0, has_toc = false, past_position = info.past_position, hidden = info.hidden }
    end
    local depth_shown, deepest = fitDepth(items, OUTLINE_MAX_ENTRIES)
    local shown = keepUpToDepth(items, depth_shown)
    local omitted = 0
    if #shown > OUTLINE_MAX_ENTRIES then
        omitted = #shown - OUTLINE_MAX_ENTRIES
        local cut = {}
        for i = 1, OUTLINE_MAX_ENTRIES do cut[i] = shown[i] end
        shown = cut
    end
    return {
        has_toc = true,
        entries = shown,
        total = #items,
        depth_shown = depth_shown,
        deepest = deepest,
        omitted = omitted,
        past_position = info.past_position,
        hidden = info.hidden,
        reading_scope = self.reading_scope,
    }
end

function BookTools:toc(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end
    self:logDocumentState("toc")

    local max_snippet_chars = clamp(args.max_snippet_chars or DEFAULT_TOC_SNIPPET_CHARS, 0, MAX_TOC_SNIPPET_CHARS)
    local max_entries = clamp(args.max_entries or MAX_TOC_ENTRIES, 1, MAX_TOC_ENTRIES)
    local max_depth = tonumber(args.max_depth)
    local title_filter = type(args.title_contains) == "string" and trim(args.title_contains):lower() or nil
    if title_filter == "" then title_filter = nil end

    local all_items, info = self:collectTocEntries()
    local current_page, total_pages = info.current_page, info.total_pages
    local eligible = {}
    for _idx, item in ipairs(all_items) do
        if (not max_depth or item.depth <= max_depth)
            and (not title_filter or item.title:lower():find(title_filter, 1, true) ~= nil) then
            table.insert(eligible, item)
        end
    end

    -- Depth fitting: without an explicit max_depth, an overflowing list drops its deepest
    -- levels until it fits, so the structure survives instead of the first N entries.
    local candidates = eligible
    local depth_shown, deepest = nil, nil
    if not max_depth and #eligible > max_entries then
        depth_shown, deepest = fitDepth(eligible, max_entries)
        if depth_shown < deepest then
            candidates = keepUpToDepth(eligible, depth_shown)
        else
            depth_shown = nil
        end
    end

    local entries = {}
    for i = 1, math.min(#candidates, max_entries) do
        local item = candidates[i]
        local snippet = ""
        if max_snippet_chars > 0 then
            snippet = excerpt(self:getRangeText(item.start_page, math.min(item.start_page, item.end_page), max_snippet_chars), max_snippet_chars)
        end
        table.insert(entries, {
            title = item.title,
            depth = item.depth,
            start_page = item.start_page,
            end_page = item.end_page,
            snippet = snippet,
            path = item.path,
            continues_past_position = item.continues_past_position,
        })
    end

    local result = {
        ok = true,
        scope = { start_page = 1, end_page = current_page },
        entry_count = #entries,
        total_entries = #eligible,
        truncated = #eligible > #entries,
        depth_shown = depth_shown,
        entries = entries,
    }
    if not info.has_toc then
        addNote(result, string.format("This book has no table of contents; pages 1-%d are readable.", current_page))
    elseif #eligible == 0 and (title_filter or max_depth) then
        addNote(result, "No entries match the given title_contains / max_depth filters within the readable range.")
    end
    if depth_shown then
        addNote(result, string.format("The contents has %d matching entries, more than the %d-per-call limit, so only levels 1-%d are listed (%d entries%s); deeper levels exist down to level %d. Call again with max_depth=%d and title_contains=<a section title> to see one section's sub-entries.",
            #eligible, MAX_TOC_ENTRIES, depth_shown, #candidates,
            #candidates > #entries and string.format(", the first %d shown", #entries) or "",
            deepest, depth_shown + 1))
    end
    if #candidates > #entries then
        addNote(result, string.format("Showing entries 1-%d of %d matching entries in document order (limit %d per call). Narrow with max_depth (1 = top level) or title_contains.",
            #entries, #candidates, MAX_TOC_ENTRIES))
    end
    if info.past_position > 0 and self.reading_scope ~= "full" then
        addNote(result, string.format("%d entries start after the reader's current position (page %d of %d) and were not listed; spoiler protection keeps them out of reach, so say so rather than guessing the later structure.",
            info.past_position, current_page, total_pages))
    end
    if info.hidden > 0 then
        addNote(result, string.format("%d entries are in sections the reader has hidden (KOReader hidden flows) and were not listed.", info.hidden))
    end
    return result
end

function BookTools:execute(name, args)
    if name == "search_book" then
        return self:searchBook(args)
    elseif name == "read_around" then
        return self:readAround(args)
    elseif name == "toc" then
        return self:toc(args)
    end
    return { ok = false, error = "unknown tool: " .. tostring(name) }
end

return BookTools
