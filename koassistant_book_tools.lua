local ContextExtractor = require("koassistant_context_extractor")
local ScopeResolver = require("koassistant_scope_resolver")
local logger = require("koassistant_logger")

local BookTools = {}
BookTools.__index = BookTools

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

local function squeeze(text)
    return trim((text or ""):gsub("%s+", " "))
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
        text = text:lower()
    end
    return text
end

local function tokenize(text, case_sensitive)
    text = text or ""
    if not case_sensitive then
        text = text:lower()
    end
    local tokens = {}
    local seen = {}
    for token in text:gmatch("[%w']+") do
        if token ~= "" and not seen[token] then
            seen[token] = true
            table.insert(tokens, token)
        end
    end
    return tokens
end

local function cleanWord(word, case_sensitive)
    word = tostring(word or ""):gsub("^%W+", ""):gsub("%W+$", "")
    if not case_sensitive then
        word = word:lower()
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

local function splitSentences(text)
    text = (text or ""):gsub("[\r\n]+", ". ")
    local sentences = {}
    for sentence in text:gmatch("[^%.%!%?]+[%.%!%?]?") do
        local current = squeeze(sentence)
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

local function tokenThreshold(token)
    local len = #token
    if len <= 3 then return 0 end
    return math.max(1, math.floor(len * 0.25))
end

local function allTokensPresent(tokens, haystack)
    for _, token in ipairs(tokens) do
        if not haystack:find(token, 1, true) then
            return false
        end
    end
    return true
end

local function allTokensFuzzy(tokens, sentence_tokens)
    for _, query_token in ipairs(tokens) do
        local threshold = tokenThreshold(query_token)
        local matched = false
        for _, sentence_token in ipairs(sentence_tokens) do
            if threshold == 0 then
                matched = query_token == sentence_token
            elseif levenshteinWithin(query_token, sentence_token, threshold) then
                matched = true
            end
            if matched then break end
        end
        if not matched then return false end
    end
    return true
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
    instance.page_cache = {}
    instance.sentence_cache = {}   -- page -> sentences (split once, reused by every query)
    instance.token_cache = {}      -- "ci"/"cs" -> page -> sentence index -> tokens
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

function BookTools:getScope()
    local total_pages = self:getTotalPages()
    local current_page = self:getCurrentPage() or total_pages
    return {
        start_page = 1,
        current_page = current_page,
        end_page = self:getReadCeiling(),
        total_pages = total_pages,
        reading_scope = self.reading_scope,
    }
end

function BookTools:getPageText(page, max_chars)
    page = tonumber(page)
    if not page then return "" end
    local total_pages = self:getTotalPages()
    if total_pages <= 0 or page < 1 or page > total_pages then return "" end

    local cached = self.page_cache[page]
    if cached then return cached end

    local ok, result = pcall(function()
        return self.extractor:getPageRangeText(page, page, { max_chars = max_chars or 20000 })
    end)
    local text = ok and result and result.text or ""
    self.page_cache[page] = text
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

function BookTools:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive, tokens_fn)
    local normalized_sentence = normalizeText(sentence, case_sensitive)
    local normalized_query = normalizeText(query, case_sensitive)

    if normalized_sentence:find(normalized_query, 1, true) then
        return 100 + math.min(#normalized_query, 40), "phrase"
    end
    if allTokensPresent(query_tokens, normalized_sentence) then
        return 70 + #query_tokens, "tokens"
    end
    if fuzzy then
        local sentence_tokens = tokens_fn and tokens_fn() or tokenize(sentence, case_sensitive)
        if allTokensFuzzy(query_tokens, sentence_tokens) then
            return 45 + #query_tokens, "fuzzy"
        end
    end
    return 0, nil
end

function BookTools:collectQueries(args)
    local queries = {}
    local seen = {}
    local function push(value)
        local cleaned = trim(value)
        if cleaned == "" then return end
        local key = cleaned:lower()
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

    for page = 1, current_page do
        local sentences = self:getSentences(page)
        local page_hits = 0
        local first_hit_id = nil
        local last_hit_id = nil
        for index, sentence in ipairs(sentences) do
            local score, match_type, position = 0, nil, nil
            if literal then
                position = normalizeText(sentence, case_sensitive):find(normalized_query, 1, true)
                if position then
                    score, match_type = 100 + math.min(#normalized_query, 40), "phrase"
                end
            else
                score, match_type = self:scoreSentence(sentence, query, query_tokens, fuzzy, case_sensitive,
                    function() return self:getSentenceTokens(page, index, sentence, case_sensitive) end)
            end
            if score > 0 then
                local hit_id = string.format("q%d:p%d:%d", q_index, page, index)
                local hit = {
                    hit_id = hit_id,
                    page = page,
                    sentence_index = index,
                    score = score,
                    match_type = match_type,
                    snippet = literal and literalExcerpt(sentence, position, #normalized_query)
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

function BookTools:toc(args)
    args = args or {}
    if not self:isAvailable() then
        return { ok = false, error = "book text is not available" }
    end
    self:logDocumentState("toc")

    local current_page = self:getReadCeiling()
    local total_pages = self:getTotalPages()
    local max_snippet_chars = clamp(args.max_snippet_chars or DEFAULT_TOC_SNIPPET_CHARS, 0, MAX_TOC_SNIPPET_CHARS)
    local max_entries = clamp(args.max_entries or MAX_TOC_ENTRIES, 1, MAX_TOC_ENTRIES)
    local max_depth = tonumber(args.max_depth)
    local title_filter = type(args.title_contains) == "string" and trim(args.title_contains):lower() or nil
    if title_filter == "" then title_filter = nil end
    local toc, hidden_count = self:getEffectiveToc()
    local entries = {}
    local eligible = 0
    local past_position = 0
    local ancestors = {}

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
                local matches = end_page >= start_page
                    and (not max_depth or depth <= max_depth)
                    and (not title_filter or (entry.title or ""):lower():find(title_filter, 1, true) ~= nil)
                if matches then
                    eligible = eligible + 1
                    if #entries < max_entries then
                        local path = {}
                        for d = 1, depth - 1 do
                            if ancestors[d] then table.insert(path, ancestors[d]) end
                        end
                        local snippet = ""
                        if max_snippet_chars > 0 then
                            snippet = excerpt(self:getRangeText(start_page, math.min(start_page, end_page), max_snippet_chars), max_snippet_chars)
                        end
                        local item = {
                            title = entry.title or "",
                            depth = depth,
                            start_page = start_page,
                            end_page = end_page,
                            snippet = snippet,
                        }
                        if #path > 0 then item.path = table.concat(path, " > ") end
                        if end_page == current_page and current_page < total_pages then
                            item.continues_past_position = true
                        end
                        table.insert(entries, item)
                    end
                end
            end
        end
    end

    local result = {
        ok = true,
        scope = { start_page = 1, end_page = current_page },
        entry_count = #entries,
        total_entries = eligible,
        truncated = eligible > #entries,
        entries = entries,
    }
    if not toc or #toc == 0 then
        addNote(result, string.format("This book has no table of contents; pages 1-%d are readable.", current_page))
    elseif eligible == 0 and (title_filter or max_depth) then
        addNote(result, "No entries match the given title_contains / max_depth filters within the readable range.")
    end
    if eligible > #entries then
        addNote(result, string.format("Showing entries 1-%d of %d matching entries in document order (limit %d per call). Narrow with max_depth (1 = top level) or title_contains.",
            #entries, eligible, MAX_TOC_ENTRIES))
    end
    if past_position > 0 and self.reading_scope ~= "full" then
        addNote(result, string.format("%d entries start after the reader's current position (page %d of %d) and were not listed; spoiler protection keeps them out of reach, so say so rather than guessing the later structure.",
            past_position, current_page, total_pages))
    end
    if hidden_count and hidden_count > 0 then
        addNote(result, string.format("%d entries are in sections the reader has hidden (KOReader hidden flows) and were not listed.", hidden_count))
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
