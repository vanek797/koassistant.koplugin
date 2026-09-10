-- Unit tests for koassistant_book_tools.lua

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."

    package.path = table.concat({
        plugin_dir .. "/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end

setupPaths()
require("mock_koreader")

local BookTools = require("koassistant_book_tools")

local TestRunner = require("test_runner"):new()

local function makeToolsWithPages(pages, current_page, toc, scope)
    local ui = {
        document = {
            info = {
                has_pages = true,
                number_of_pages = #pages,
            },
            getPageText = function(_self, page)
                return pages[page] or ""
            end,
        },
        view = {
            state = {
                page = current_page or #pages,
            },
        },
        toc = {
            toc = toc or {
                { title = "Chapter 1", page = 1, depth = 1 },
                { title = "Chapter 2", page = 3, depth = 1 },
                { title = "Unread", page = 4, depth = 1 },
            },
        },
    }
    return BookTools:new(ui, { enable_book_text_extraction = true, reading_scope = scope })
end

local DEMO_PAGES = {
    "Alice saw the white rabbit. Daisy was mentioned in a letter.",
    "The garden path curved behind the old house.",
    "Daisey carried a lantern into the cellar.",
    "This spoiler is beyond the current page.",
}

local function makeTools()
    return makeToolsWithPages(DEMO_PAGES, 3)
end

-- Same book/position but with full ("whole document") reading scope (spoiler-free off).
local function makeFullTools()
    return makeToolsWithPages(DEMO_PAGES, 3, nil, "full")
end

print("")
print(string.rep("=", 50))
print("  Unit Tests: Book Tools")
print(string.rep("=", 50))

TestRunner:test("searches only up to the current page", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].total_hits, 0, "unread total hits")
end)

TestRunner:test("finds exact matches case-insensitively", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 1, "exact page")
    TestRunner:assertEqual(result.queries[1].results[1].hit_id, "q1:p1:2", "namespaced hit id")
end)

TestRunner:test("finds fuzzy matches", function()
    local tools = makeTools()
    local result = tools:searchBook({ query = "lantrn" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 3, "fuzzy page")
end)

local function hasNote(notes, needle)
    for _idx, note in ipairs(notes or {}) do
        if note:find(needle, 1, true) then return true end
    end
    return false
end

TestRunner:test("search caps the hits it shows at 12, keeps exact totals and says so", function()
    local pages = {}
    for page = 1, 15 do
        pages[page] = "Daisy appears on page " .. page .. "."
    end
    local tools = makeToolsWithPages(pages, 15, {})
    local result = tools:searchBook({ query = "Daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.total_hits, 15, "total hits")
    TestRunner:assertEqual(result.query_count, 1, "query count")
    local block = result.queries[1]
    TestRunner:assertEqual(block.total_hits, 15, "block total hits exact")
    TestRunner:assertEqual(#block.results, 12, "12 hits shown by default")
    TestRunner:assertEqual(block.shown_hits, 12, "shown_hits")
    TestRunner:assertEqual(block.matching_pages, 15, "matching pages")
    TestRunner:assertEqual(block.page_summary[15].page, 15, "page_summary keeps every page")
    TestRunner:assertEqual(block.results[1].snippet, "Daisy appears on page 1.", "compact snippet")
    TestRunner:assertTrue(hasNote(block.notes, "Showing 12 of 15 hits"), "cap stated in a note")
    TestRunner:assertTrue(result.notes == nil, "full scope at the last page: no range note")
    local raised = tools:searchBook({ query = "Daisy", max_hits = 20 })
    TestRunner:assertEqual(#raised.queries[1].results, 15, "max_hits raises the cap")
    TestRunner:assertTrue(raised.queries[1].notes == nil, "nothing left out: no note")
    local ceiling = tools:searchBook({ query = "Daisy", max_hits = 400 })
    TestRunner:assertEqual(#ceiling.queries[1].results, 15, "max_hits above the ceiling still works")
end)

TestRunner:test("search spreads shown hits across pages instead of the first pages only", function()
    local pages = {}
    for page = 1, 8 do
        pages[page] = "Daisy one. Daisy two. Daisy three."
    end
    local tools = makeToolsWithPages(pages, 8, {})
    local block = tools:searchBook({ query = "Daisy" }).queries[1]
    TestRunner:assertEqual(block.total_hits, 24, "24 hits in total")
    TestRunner:assertEqual(#block.results, 12, "12 shown")
    local pages_seen = {}
    for _idx, hit in ipairs(block.results) do pages_seen[hit.page] = (pages_seen[hit.page] or 0) + 1 end
    local distinct = 0
    for _page, count in pairs(pages_seen) do
        distinct = distinct + 1
        TestRunner:assertTrue(count <= 2, "at most 2 hits per page")
    end
    TestRunner:assertEqual(distinct, 6, "hits come from 6 different pages")
end)

TestRunner:test("a query without word tokens matches literally instead of failing", function()
    local tools = makeToolsWithPages({ "東京の空は青く、遠くに山が見えた。", "second page" }, 2, {})
    local result = tools:searchBook({ query = "東京" })
    TestRunner:assertTrue(result.ok, "search ok")
    local block = result.queries[1]
    TestRunner:assertEqual(block.total_hits, 1, "literal hit found")
    TestRunner:assertEqual(block.results[1].match_type, "phrase", "phrase match")
    TestRunner:assertTrue(block.results[1].snippet:find("東京", 1, true) ~= nil, "snippet contains the match")
    TestRunner:assertTrue(hasNote(block.notes, "literal substring"), "literal matching stated")
    TestRunner:assertEqual(block.error, nil, "no error")
end)

TestRunner:test("search under spoiler protection states the readable range", function()
    local tools = makeTools()  -- current page 3 of 4, scope current
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertEqual(result.queries[1].total_hits, 0, "no hit within range")
    TestRunner:assertTrue(hasNote(result.notes, "pages 1-3 of 4 only"), "range note names the ceiling")
    TestRunner:assertTrue(hasNote(result.notes, "not evidence"), "range note says zero hits are inconclusive")
    local full = makeFullTools():searchBook({ query = "spoiler" })
    TestRunner:assertTrue(full.notes == nil, "full scope carries no range note")
end)

TestRunner:test("hidden flows are honored and reported on search and toc", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 4, nil, "full")
    local document = tools.ui.document
    document.hasHiddenFlows = function() return true end
    document.getPageFlow = function(_self, page) return page >= 3 and 1 or 0 end
    local search = tools:searchBook({ query = "lantern" })
    TestRunner:assertEqual(search.queries[1].total_hits, 0, "hidden page not searched")
    TestRunner:assertTrue(hasNote(search.notes, "2 of 4 pages are in sections the reader has hidden"), "hidden pages counted")
    local toc = tools:toc()
    TestRunner:assertEqual(toc.entry_count, 1, "only the visible entry listed")
    TestRunner:assertTrue(hasNote(toc.notes, "2 entries are in sections the reader has hidden"), "hidden entries counted")
end)

TestRunner:test("search snippets are concordance-sized", function()
    local tools = makeToolsWithPages({
        "One two three four five Daisy six seven eight nine ten eleven.",
    }, 1, {})
    local result = tools:searchBook({ query = "Daisy" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].snippet, "One two three four five Daisy six seven eight nine ten...", "concordance snippet")
end)

TestRunner:test("multi-query search returns one block per term", function()
    local tools = makeTools()
    local result = tools:searchBook({ queries = { "daisy", "lantern" } })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.query_count, 2, "query count")
    TestRunner:assertEqual(#result.queries, 2, "blocks count")
    TestRunner:assertEqual(result.queries[1].query, "daisy", "first query")
    TestRunner:assertEqual(result.queries[2].query, "lantern", "second query")
    TestRunner:assertEqual(result.queries[1].results[1].hit_id, "q1:p1:2", "first block hit_id")
    TestRunner:assertEqual(result.queries[2].results[1].hit_id, "q2:p3:1", "second block hit_id")
    TestRunner:assertTrue(result.total_hits >= 2, "aggregate total hits")
end)

TestRunner:test("read_around accepts namespaced multi-query hit_ids", function()
    local tools = makeTools()
    local search = tools:searchBook({ queries = { "daisy", "lantern" } })
    local id1 = search.queries[1].results[1].hit_id
    local id2 = search.queries[2].results[1].hit_id
    local result = tools:readAround({ hit_ids = { id1, id2 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.target_count, 2, "target count")
    TestRunner:assertEqual(result.results[1].page, 1, "first page")
    TestRunner:assertEqual(result.results[2].page, 3, "second page")
end)

TestRunner:test("reads around a page with current-page clamp", function()
    local tools = makeTools()
    local result = tools:readAround({ page = 2, before_pages = 1, after_pages = 3 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.range.start_page, 1, "start page")
    TestRunner:assertEqual(result.range.end_page, 3, "end page")
end)

TestRunner:test("reads around multiple targets in one call", function()
    local tools = makeTools()
    local result = tools:readAround({ pages = { 1, 3 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.target_count, 2, "target count")
    TestRunner:assertEqual(result.results[1].page, 1, "first page")
    TestRunner:assertEqual(result.results[2].page, 3, "second page")
end)

TestRunner:test("returns toc entries and excludes unread chapters", function()
    local tools = makeTools()
    local result = tools:toc({ max_snippet_chars = 80 })
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entry_count, 2, "entry count")
    TestRunner:assertEqual(result.entries[2].title, "Chapter 2", "second title")
end)

TestRunner:test("toc omits snippets by default", function()
    local tools = makeTools()
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entries[1].snippet, "", "default snippet")
end)

-- Reading scope: "full" lets the tools read the whole document (research / non-fiction)
TestRunner:test("full reading scope searches beyond the current page", function()
    local tools = makeFullTools()
    local result = tools:searchBook({ query = "spoiler" })
    TestRunner:assertTrue(result.ok, "search ok")
    TestRunner:assertEqual(result.queries[1].results[1].page, 4, "reads ahead to page 4")
end)

TestRunner:test("full reading scope read_around reaches a later page", function()
    local tools = makeFullTools()
    local result = tools:readAround({ page = 4, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertEqual(result.range.end_page, 4, "reads page 4")
    TestRunner:assertTrue(result.text:find("spoiler", 1, true) ~= nil, "page-4 text returned")
end)

TestRunner:test("full reading scope toc includes later chapters", function()
    local tools = makeFullTools()
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "toc ok")
    TestRunner:assertEqual(result.entry_count, 3, "includes the unread chapter")
    TestRunner:assertEqual(result.entries[3].title, "Unread", "last chapter title")
end)

TestRunner:test("getScope reports the reading scope and ceiling", function()
    TestRunner:assertEqual(makeTools():getScope().reading_scope, "current", "current scope")
    TestRunner:assertEqual(makeTools():getScope().end_page, 3, "current ceiling = current page")
    TestRunner:assertEqual(makeFullTools():getScope().reading_scope, "full", "full scope")
    TestRunner:assertEqual(makeFullTools():getScope().end_page, 4, "full ceiling = last page")
end)

-- Strict UTF-8 validator (the same rules KOReader's util.fixUtf8 applies).
local function isValidUtf8(str)
    local pos, len = 1, #str
    while pos <= len do
        if str:find("^[%z\1-\127]", pos) then pos = pos + 1
        elseif str:find("^[\194-\223][\128-\191]", pos) then pos = pos + 2
        elseif str:find("^\224[\160-\191][\128-\191]", pos)
            or str:find("^[\225-\236][\128-\191][\128-\191]", pos)
            or str:find("^\237[\128-\159][\128-\191]", pos)
            or str:find("^[\238-\239][\128-\191][\128-\191]", pos) then pos = pos + 3
        elseif str:find("^\240[\144-\191][\128-\191][\128-\191]", pos)
            or str:find("^[\241-\243][\128-\191][\128-\191][\128-\191]", pos)
            or str:find("^\244[\128-\143][\128-\191][\128-\191]", pos) then pos = pos + 4
        else
            return false
        end
    end
    return true
end

-- Multi-byte text: every cut a tool result passes through must land on a character
-- boundary, or the JSON request ships stray bytes and the provider rejects it.
local CJK_SENTENCE = "東京の空は青く、遠くに山が見えた。"  -- 3-byte chars, no spaces

TestRunner:test("read_around: a multi-byte page cut at the read budget stays valid UTF-8", function()
    local big = string.rep(CJK_SENTENCE, 400)  -- ~20K bytes, over MAX_READ_CHARS (8000)
    local tools = makeToolsWithPages({ big, "second page" }, 2)
    local result = tools:readAround({ page = 1, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(result.ok, "read ok")
    TestRunner:assertTrue(#result.text <= 8000, "read budget honored in bytes")
    TestRunner:assertTrue(isValidUtf8(result.text), "no partial character at either end")
    TestRunner:assertTrue(result.text:sub(-3) == "...", "excerpt marker kept")
end)

TestRunner:test("toc: a multi-byte chapter snippet cut at max_snippet_chars stays valid UTF-8", function()
    local tools = makeToolsWithPages({ string.rep(CJK_SENTENCE, 20), "x" }, 2,
        { { title = "第一章", page = 1, depth = 1 }, { title = "第二章", page = 2, depth = 1 } })
    local result = tools:toc({ max_snippet_chars = 100 })
    TestRunner:assertTrue(result.ok, "toc ok")
    local snippet = result.entries[1].snippet
    TestRunner:assertTrue(#snippet <= 100, "snippet budget honored")
    TestRunner:assertTrue(isValidUtf8(snippet), "snippet has no partial character")
end)

TestRunner:test("search_book: a multi-byte sentence chunked past MAX_SENTENCE_CHUNK stays valid UTF-8", function()
    -- One 'sentence' with no terminator and no spaces, longer than the 700-byte chunk.
    local run = string.rep("東京", 400) .. " tokyo"
    local tools = makeToolsWithPages({ run, "y" }, 2)
    local result = tools:searchBook({ query = "tokyo" })
    TestRunner:assertTrue(result.ok, "search ok")
    local block = result.queries[1]
    TestRunner:assertTrue((block.total_hits or 0) >= 1, "ASCII token still found")
    for _idx, hit in ipairs(block.results or {}) do
        TestRunner:assertTrue(isValidUtf8(hit.snippet or ""), "snippet " .. _idx .. " valid UTF-8")
    end
end)

local BIG_TOC = {
    { title = "Volume 1", page = 1, depth = 1 },
    { title = "Part I", page = 1, depth = 2 },
    { title = "Archetypes of the Collective Unconscious", page = 1, depth = 3 },
    { title = "Concerning Rebirth", page = 2, depth = 3 },
    { title = "Volume 2", page = 3, depth = 1 },
    { title = "Chapter 1", page = 3, depth = 2 },
    { title = "Volume 3", page = 4, depth = 1 },
    { title = "Chapter 1", page = 4, depth = 2 },
}

TestRunner:test("toc: exact totals, filters and parent paths", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 4, BIG_TOC, "full")
    local all = tools:toc()
    TestRunner:assertEqual(all.entry_count, 8, "all entries")
    TestRunner:assertEqual(all.total_entries, 8, "total_entries exact")
    TestRunner:assertEqual(all.truncated, false, "not truncated")
    TestRunner:assertEqual(all.entries[4].path, "Volume 1 > Part I", "parent path")
    TestRunner:assertEqual(all.entries[1].path, nil, "top level has no path")
    local top = tools:toc({ max_depth = 1 })
    TestRunner:assertEqual(top.entry_count, 3, "max_depth=1 lists the volumes")
    TestRunner:assertEqual(top.entries[3].title, "Volume 3", "last volume")
    local rebirth = tools:toc({ title_contains = "rebirth" })
    TestRunner:assertEqual(rebirth.entry_count, 1, "title filter, case-insensitive")
    TestRunner:assertEqual(rebirth.entries[1].path, "Volume 1 > Part I", "filtered entry keeps its path")
    local none = tools:toc({ title_contains = "zzz" })
    TestRunner:assertEqual(none.entry_count, 0, "no match")
    TestRunner:assertTrue(hasNote(none.notes, "No entries match"), "no-match note")
    local capped = tools:toc({ max_entries = 2 })
    TestRunner:assertEqual(capped.entry_count, 2, "cap honored")
    TestRunner:assertEqual(capped.total_entries, 8, "total still exact")
    TestRunner:assertEqual(capped.truncated, true, "truncated flag")
    TestRunner:assertTrue(hasNote(capped.notes, "Showing entries 1-2 of 8"), "cap stated in a note")
end)

TestRunner:test("toc under spoiler protection counts the entries past the reader", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 2, BIG_TOC)  -- reader at page 2 of 4
    local result = tools:toc()
    TestRunner:assertEqual(result.entry_count, 4, "entries up to the reader")
    TestRunner:assertTrue(hasNote(result.notes, "4 entries start after the reader's current position"), "later entries counted")
    TestRunner:assertEqual(result.entries[1].continues_past_position, true, "Volume 1 continues past the reader")
    TestRunner:assertEqual(result.entries[3].continues_past_position, nil, "closed entry has no marker")
end)

TestRunner:test("toc without a table of contents returns no entries and says so", function()
    local tools = makeToolsWithPages(DEMO_PAGES, 3, {})
    local result = tools:toc()
    TestRunner:assertTrue(result.ok, "ok")
    TestRunner:assertEqual(result.entry_count, 0, "no synthetic entry")
    TestRunner:assertTrue(hasNote(result.notes, "no table of contents"), "stated")
end)

TestRunner:test("read_around states a moved target and truncated batches", function()
    local tools = makeTools()  -- reader at page 3 of 4
    local moved = tools:readAround({ page = 4, before_pages = 0, after_pages = 0 })
    TestRunner:assertTrue(moved.ok, "ok")
    TestRunner:assertEqual(moved.page, 3, "clamped to the reader")
    TestRunner:assertTrue(hasNote(moved.notes, "Page 4 is past the readable range"), "move stated")
    TestRunner:assertEqual(moved.chars, #moved.text, "chars describes the returned text")
    local batch = tools:readAround({ pages = { 1, 2, 3, 1, 2 }, before_pages = 0, after_pages = 0 })
    TestRunner:assertEqual(batch.target_count, 4, "4 targets read")
    TestRunner:assertTrue(hasNote(batch.notes, "Read 4 of 5 requested targets"), "batch cap stated")
    local skipped = tools:readAround({ hit_ids = { "nonsense", "q1:p1:1" }, before_pages = 0, after_pages = 0 })
    TestRunner:assertEqual(skipped.target_count, 1, "one resolved")
    TestRunner:assertTrue(hasNote(skipped.notes, "1 target(s) could not be resolved"), "skip stated")
end)

return TestRunner:summary()
