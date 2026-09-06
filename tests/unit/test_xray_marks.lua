-- State-machine tests for the real passive-marking module with bounded KOReader mocks.

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua", tests_dir .. "/?.lua", tests_dir .. "/lib/?.lua", package.path,
    }, ";")
    return plugin_dir
end
local PLUGIN_DIR = setupPaths()
local mocked_names = {
    "logger", "koassistant_logger", "ui/uimanager", "ui/time", "ui/geometry",
    "device", "ffi/blitbuffer", "libs/libkoreader-lfs", "koassistant_action_cache",
    "koassistant_xray_parser", "koassistant_xray_auto", "koassistant_context_extractor",
    "koassistant_book_settings", "koassistant_xray_marks_index", "koassistant_xray_marks",
    "ffi/utf8proc",
}
local saved_modules = {}
for _, name in ipairs(mocked_names) do saved_modules[name] = { package.loaded[name] } end

package.loaded["logger"] = {
    warn = function(...) print("[WARN]", ...) end, info = function() end, err = function() end,
    dbg = function() end, LvDEBUG = function() end,
}
package.loaded["koassistant_logger"] = nil

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print(string.format("\n  [%s]", name)) end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)))
    end
end

local scheduled, cancelled, dirty
local fixture
local active_plugin
local UIManager = {}
function UIManager:scheduleIn(_delay, fn) scheduled[#scheduled + 1] = fn end
function UIManager:unschedule(fn) cancelled[fn] = true end
function UIManager:setDirty(...)
    if fixture and fixture.dirty_error_once and select("#", ...) >= 3 then
        fixture.dirty_error_once = nil
        error("simulated refresh failure")
    end
    dirty = dirty + 1
end
function UIManager:isWidgetShown(widget) return widget and widget.shown or false end
function UIManager:nextTick(fn) scheduled[#scheduled + 1] = fn end
package.loaded["ui/uimanager"] = UIManager
package.loaded["ui/time"] = {
    now = function() return 0 end,
    to_ms = function() return 0 end,
}
package.loaded["ui/geometry"] = {
    new = function(_self, value) return value end,
}
package.loaded["device"] = {
    screen = { scaleBySize = function(_self, value) return value end },
}
package.loaded["ffi/blitbuffer"] = { COLOR_DARK_GRAY = 1 }
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return nil end }

local ActionCache = {}
function ActionCache.getPath() return "/missing/cache" end
function ActionCache.getUserAliasesPath() return "/missing/aliases" end
function ActionCache.getXrayLadderPath() return "/missing/ladder" end
function ActionCache.getXrayCache()
    if not fixture.live then return nil end
    if fixture.live.result then return fixture.live end
    return { timestamp = fixture.live.timestamp, progress_decimal = fixture.live.progress_decimal,
        result = fixture.live }
end
function ActionCache.getSectionXrays()
    local out = {}
    for i, section in ipairs(fixture.sections or {}) do
        local data = section.data
        if not data.result then
            data = { timestamp = data.timestamp, result = data }
        end
        out[i] = { key = section.key, data = data }
    end
    return out
end
function ActionCache.getXrayLadder() return {} end
function ActionCache.groupXrays() return {}, "none" end
function ActionCache.getUserAliases() return {} end
function ActionCache.getSectionPageRange()
    fixture.range_calls = fixture.range_calls + 1
    error("section range resolution must not be called")
end
package.loaded["koassistant_action_cache"] = ActionCache

local Parser = {
    TEXT_MATCH_EXCLUDED = {},
    isJSON = function(result) return type(result) == "table" end,
    parse = function(result) return result end,
    mergeUserAliases = function() end,
    buildMarkEntities = function(data) return data.entities or {} end,
    buildLedgerMarkEntities = function() return {} end,
    getCategories = function() return {} end,
    normalizeArabic = function(text) return text end,
    handleContainsWord = function(longer, shorter)
        return longer ~= shorter and longer:find(shorter, 1, true) ~= nil
    end,
}
package.loaded["koassistant_xray_parser"] = Parser
package.loaded["koassistant_xray_auto"] = { pickAheadRung = function() return nil end }
package.loaded["koassistant_context_extractor"] = {
    new = function()
        return { getVisiblePageText = function() return { text = fixture.hay or "" } end }
    end,
}
package.loaded["koassistant_book_settings"] = {
    resolveXrayMarking = function()
        return fixture.marking or {
            enabled = true, tap = true, density = "first", families = "all", ahead = false,
        }
    end,
}
local PersistentIndex = {}
function PersistentIndex.start(opts)
    if fixture.persistence == false then return nil, "unsupported" end
    local state = fixture.persistence
    if not state or (state._fixture_default and state.closed) then
        state = { status = "ready", disposition = "absent", terms = {}, _fixture_default = true }
        fixture.persistence = state
    end
    state.disposition = state.disposition or "absent"
    state.terms = state.terms or {}
    state.on_ready = opts.on_ready
    state.puts, state.evictions = state.puts or {}, state.evictions or {}
    state.dom_open_identity = opts.dom_open_identity
    return state
end
function PersistentIndex.isPending(state) return state and state.status == "pending" end
function PersistentIndex.isReady(state) return state and state.status == "ready" end
function PersistentIndex.allowColdSearch(state)
    -- Mirror the real module: the index is additive; session-native search is
    -- withheld only while a warm cache is still pending and for a read-only
    -- recovery.
    if state and state.status == "pending" then return false end
    if state and state.status == "ready" and state.disposition == "recovered_read_only" then
        return false
    end
    return true
end
function PersistentIndex.get(state, key)
    local entry = state and state.terms[key]
    if not entry then return nil end
    local hits = {}
    for i, h in ipairs(entry.hits or {}) do
        hits[i] = { start = h.start, e = h.e, prefix = h.prefix, suffix = h.suffix }
    end
    return { outcome = entry.outcome, hits = hits, persisted = true }
end
function PersistentIndex.put(state, key, outcome, hits)
    state.puts[#state.puts + 1] = { key = key, outcome = outcome }
    state.terms[key] = { outcome = outcome, hits = hits }
    return true
end
function PersistentIndex.evict(state, key)
    state.evictions[#state.evictions + 1] = key
    state.terms[key] = nil
end
function PersistentIndex.pause(state) if state then state.paused = true end end
function PersistentIndex.resume(state)
    if state then state.paused = nil; state.resume_count = (state.resume_count or 0) + 1 end
end
function PersistentIndex.close(state) if state then state.closed = true end end
package.loaded["koassistant_xray_marks_index"] = PersistentIndex
-- Strict (normalize=false) 1:1 lowercase over ASCII, Latin-1, and Cyrillic —
-- enough to exercise the module's non-ASCII case folding for descriptors and
-- persisted live-text verification. normalize=true records the fold-mode
-- calls (NFKC on device) so tests can prove which path was exercised.
local utf8_fold_calls = {}
package.loaded["ffi/utf8proc"] = {
    _calls = utf8_fold_calls,
    lowercase = function(str, normalize)
        utf8_fold_calls[#utf8_fold_calls + 1] = normalize
        local out, i, n = {}, 1, #str
        while i <= n do
            local b = str:byte(i)
            if b < 0x80 then
                if b >= 65 and b <= 90 then b = b + 32 end
                out[#out + 1] = string.char(b)
                i = i + 1
            elseif b == 0xC3 then
                local b2 = str:byte(i + 1)
                if b2 and b2 >= 0x80 and b2 <= 0x9F then
                    out[#out + 1] = string.char(0xC3, b2 + 0x20)
                else
                    out[#out + 1] = string.char(0xC3, b2 or 0)
                end
                i = i + 2
            elseif b == 0xD0 then
                local b2 = str:byte(i + 1)
                if b2 and b2 >= 0x90 and b2 <= 0xAF then
                    out[#out + 1] = string.char(0xD0, b2 + 0x20)
                elseif b2 == 0x81 then
                    out[#out + 1] = "\209\145" -- Ё -> ё
                else
                    out[#out + 1] = string.char(0xD0, b2 or 0)
                end
                i = i + 2
            else
                local len = 1
                if b >= 0xF0 then len = 4 elseif b >= 0xE0 then len = 3 elseif b >= 0xC2 then len = 2 end
                out[#out + 1] = str:sub(i, i + len - 1)
                i = i + len
            end
        end
        return table.concat(out)
    end,
}
package.loaded["koassistant_xray_marks"] = nil
local XrayMarks = require("koassistant_xray_marks")

local function term(text, regex)
    return { text = text, norm = text:lower(), regex = regex }
end

local function entity(name, terms)
    return { name = name, family = "people", category_key = "people", terms = terms }
end

local function posValue(xp)
    if type(xp) ~= "string" then return nil end
    local page, offset = xp:match("^p(%d+):(%d+)$")
    if not page then return nil end
    return tonumber(page) * 1000 + tonumber(offset)
end

local function makeDocument(file, responses)
    local doc = {
        file = file or "/book.epub",
        info = { number_of_pages = 20 },
        page = 2,
        searches = {},
        map_calls = 0,
        box_calls = 0,
        pointer_text = {},
        range_text = {},
    }
    function doc:getCurrentPage() return self.page end
    function doc:findAllText(query, _ci, _start, _cap, is_regex, flags)
        self.searches[#self.searches + 1] = { query = query, regex = is_regex, flags = flags }
        local response = responses and responses[query]
        if type(response) == "function" then return response(self, is_regex, flags) end
        return response or {}
    end
    function doc:getPageFromXPointer(xp)
        self.map_calls = self.map_calls + 1
        local value = posValue(xp)
        return value and math.floor(value / 1000) or nil
    end
    function doc:compareXPointers(a, b)
        local av, bv = posValue(a), posValue(b)
        if not av or not bv then error("invalid xpointer") end
        return bv - av -- CRE contract used by the module: >= 0 means a <= b.
    end
    function doc:getPrevVisibleChar(xp)
        local page, offset = xp:match("^p(%d+):(%d+)$")
        if not page or tonumber(offset) == 0 then return nil end
        return string.format("p%d:%d", tonumber(page), tonumber(offset) - 1)
    end
    function doc:getNextVisibleChar(xp)
        local page, offset = xp:match("^p(%d+):(%d+)$")
        if not page then return nil end
        return string.format("p%d:%d", tonumber(page), tonumber(offset) + 1)
    end
    function doc:getTextFromXPointers(start, finish)
        local exact = self.range_text[start .. "|" .. finish]
        if exact ~= nil then return exact end
        if self.pointer_text[start] ~= nil then return self.pointer_text[start] end
        -- Unspecified adjacent characters in fixtures are ordinary boundaries.
        return " "
    end
    function doc:getScreenBoxesFromPositions(start)
        self.box_calls = self.box_calls + 1
        local value = assert(posValue(start))
        return { { x = value % 1000, y = 10, w = 20, h = 12 } }
    end
    return doc
end

local function makePlugin(doc)
    local view = { view_mode = "page", view_modules = {} }
    function view:registerViewModule(name, widget) self.view_modules[name] = widget end
    local ui = {
        document = doc,
        rolling = { rendering_hash = 12345 },
        view = view,
        dialog = {},
        doc_settings = {},
        search = {},
    }
    local plugin = {
        ui = ui,
        settings = { readSetting = function() return {} end },
    }
    active_plugin = plugin
    return plugin
end

local function reset(new_fixture)
    if active_plugin then pcall(XrayMarks.teardown, active_plugin) end
    active_plugin = nil
    scheduled, cancelled, dirty = {}, {}, 0
    fixture = new_fixture
    fixture.range_calls = 0
end

local function drain(limit)
    limit = limit or 100
    local ran = 0
    while #scheduled > 0 do
        local fn = table.remove(scheduled, 1)
        if not cancelled[fn] then fn(); ran = ran + 1 end
        if ran > limit then error("scheduled callback loop") end
    end
    return ran
end

local function hit(page, offset, length)
    return { start = string.format("p%d:%d", page, offset),
        ["end"] = string.format("p%d:%d", page, offset + (length or 5)) }
end

TestRunner:suite("queue, section policy, and layout remapping")
TestRunner:test("one queue cursor searches each demanded descriptor once and sections are range-free", function()
    reset({
        hay = "Alice Bob",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
        sections = { { key = "chapter", data = { timestamp = 2,
            entities = { entity("Bob", { term("Bob") }) } } } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) }, Bob = { hit(2, 40) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 2, "cold searches")
    TestRunner:eq(fixture.range_calls, 0, "section range calls")
    local name = XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } })
    TestRunner:eq(name, "Alice", "painted target")

    XrayMarks.onPageTurn(plugin, 2)
    drain()
    TestRunner:eq(#doc.searches, 2, "warm page does not search again")

    local mapped = doc.map_calls
    XrayMarks.onLayoutChanged(plugin, false)
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), nil,
        "layout immediately withdraws targets")
    drain()
    TestRunner:eq(#doc.searches, 2, "layout reuses raw positions")
    assert(doc.map_calls > mapped, "layout remapped retained positions")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("mapping advances in bounded batches without repeating search", function()
    local hits = {}
    for i = 1, 205 do hits[i] = hit(2, i, 1) end
    reset({
        hay = "Alice",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = hits })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    local search_tick = table.remove(scheduled, 1)
    search_tick()
    TestRunner:eq(#doc.searches, 1, "one search")
    local map_tick = table.remove(scheduled, 1)
    map_tick()
    TestRunner:eq(doc.map_calls, 200, "first 100-hit mapping batch")
    map_tick = table.remove(scheduled, 1)
    map_tick()
    TestRunner:eq(doc.map_calls, 400, "second 100-hit mapping batch")
    drain()
    TestRunner:eq(doc.map_calls, 410, "final five-hit mapping batch")
    TestRunner:eq(#doc.searches, 1, "mapping cursor does not repeat search")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("case-variant plain terms share one case-insensitive descriptor", function()
    reset({
        hay = "Alice alice",
        live = { timestamp = 1, progress_decimal = 1, entities = {
            entity("Alice One", { term("Alice") }),
            entity("Alice Two", { term("alice") }),
        } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) }, alice = { hit(2, 20) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 1, "case-insensitive native search count")
    TestRunner:eq(doc.searches[1].query, "Alice", "first equivalent payload searched")
    TestRunner:eq(doc.searches[1].flags, 0x00FF, "plain flags")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("Unicode case-variant plain terms share one descriptor", function()
    reset({
        hay = "Élodie élodie",
        live = { timestamp = 1, progress_decimal = 1, entities = {
            entity("Élodie One", { term("Élodie") }),
            entity("Élodie Two", { term("élodie") }),
        } },
    })
    local doc = makeDocument("/book.epub", { ["Élodie"] = { hit(2, 10) }, ["élodie"] = { hit(2, 20) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 1, "one native search for both Unicode spellings")
    TestRunner:eq(doc.searches[1].query, "Élodie", "first equivalent payload searched")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("plain and regex descriptors with the same display text stay distinct", function()
    reset({
        hay = "same",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Same", { term("same"), term("same", "same") }) } },
    })
    local doc = makeDocument("/book.epub", { same = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 2, "descriptor count")
    TestRunner:eq(doc.searches[1].flags, 0x00FF, "plain flags")
    TestRunner:eq(doc.searches[2].flags, 0x0001, "regex flags")
    assert(doc.searches[1].regex == false and doc.searches[2].regex == true,
        "plain and regex modes preserved")
    XrayMarks.teardown(plugin)
end)

TestRunner:suite("persistent-index integration")
TestRunner:test("verification gates cold search and a verified warm reopen avoids findAllText", function()
    local persistence = { status = "pending", terms = {} }
    reset({
        hay = "Alice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 0, "no search before identity verification")
    XrayMarks.onPageTurn(plugin, 2)
    drain()
    TestRunner:eq(#doc.searches, 0, "page turns stay gated while verification is pending")
    persistence.status = "ready"
    persistence.on_ready()
    drain()
    TestRunner:eq(#doc.searches, 1, "cold search resumes after verification")
    TestRunner:eq(#persistence.puts, 1, "verified complete result persisted")
    XrayMarks.teardown(plugin)

    local warm = { status = "ready", terms = {
        ["plain:255:alice"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:35" } } },
    } }
    fixture.persistence = warm
    local warm_doc = makeDocument("/book.epub", { Alice = function() error("must stay warm") end })
    warm_doc.pointer_text["p2:30"] = "Alice"
    local warm_plugin = makePlugin(warm_doc)
    XrayMarks.sync(warm_plugin)
    drain()
    TestRunner:eq(#warm_doc.searches, 0, "warm reopen search count")
    TestRunner:eq(XrayMarks.tapTarget(warm_plugin, { pos = { x = 31, y = 11 } }), "Alice",
        "persisted pointer remapped into a target")
    XrayMarks.teardown(warm_plugin)
end)

TestRunner:test("persisted mixed-case Unicode pointers verify against live text", function()
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["plain:255:élodie"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:36" } } },
        ["plain:255:кобра"] = { outcome = "hits",
            hits = { { start = "p2:80", e = "p2:86" } } },
    } }
    reset({
        hay = "Élodie Кобра", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1, entities = {
            entity("Élodie", { term("Élodie") }),
            entity("Кобра", { term("Кобра") }),
        } },
    })
    local doc = makeDocument("/book.epub", {
        ["Élodie"] = function() error("warm: no cold search") end,
        ["Кобра"] = function() error("warm: no cold search") end,
    })
    doc.pointer_text["p2:30"] = "Élodie"
    doc.pointer_text["p2:80"] = "Кобра"
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 0, "warm Unicode reopen searches nothing")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 31, y = 11 } }), "Élodie",
        "accented live casing verified and remapped")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 85, y = 11 } }), "Кобра",
        "Cyrillic live casing verified and remapped")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("invalid UTF-8 persisted pointer text fails closed, never prefix-matches", function()
    -- "élodie" followed by a UTF-16 surrogate encoding (ED A0 80) is not
    -- valid UTF-8: utf8proc truncates at the invalid byte, so an ASCII-only
    -- or truncation-based comparison could match the shared valid prefix.
    local poisoned = "élodie\237\160\128"
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["plain:255:élodie"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:37" } } },
    } }
    reset({
        hay = "Élodie", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Élodie", { term("Élodie") }) } },
    })
    local doc = makeDocument("/book.epub", { ["Élodie"] = { hit(2, 10) } })
    doc.pointer_text["p2:30"] = poisoned
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 0, "invalid-UTF-8 pointer has no cold fallback")
    TestRunner:eq(#persistence.evictions, 1, "invalid-UTF-8 pointer evicted")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 31, y = 11 } }), nil,
        "poisoned text never becomes a target")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("persisted hyphen and apostrophe pointers verify like the native fold", function()
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["plain:255:e-mail"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:36" } } },
        ["plain:255:dont"] = { outcome = "hits",
            hits = { { start = "p2:80", e = "p2:84" } } },
    } }
    reset({
        hay = "e-mail dont", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1, entities = {
            entity("E-Mail", { term("e-mail") }),
            entity("Dont", { term("dont") }),
        } },
    })
    local doc = makeDocument("/book.epub", {
        ["e-mail"] = function() error("warm: no cold search") end,
        ["dont"] = function() error("warm: no cold search") end,
    })
    -- CRE's 0x00FF search folds hyphens and apostrophes: a cached hit may
    -- legitimately point at the folded spelling. Verification must mirror it.
    doc.pointer_text["p2:30"] = "email"
    doc.pointer_text["p2:80"] = "don't"
    local calls = package.loaded["ffi/utf8proc"]._calls
    local before = #calls
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 0, "folded warm pointers search nothing")
    TestRunner:eq(#persistence.evictions, 0, "native-equivalent folds never evicted")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 31, y = 11 } }), "e-mail",
        "hyphen-folded hit remapped")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 85, y = 11 } }), "dont",
        "apostrophe-folded hit remapped")
    local used_nfkc = false
    for i = before + 1, #calls do
        if calls[i] == true then used_nfkc = true end
    end
    assert(used_nfkc, "verification path uses the NFKC fold mode")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("valid but wrong-text persisted XPointer is evicted without fallback", function()
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["plain:255:alice"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:35" } } },
    } }
    reset({
        hay = "Alice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    doc.pointer_text["p2:30"] = "Bob"
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 0, "wrong-text pointer has no cold fallback")
    TestRunner:eq(#persistence.evictions, 1, "wrong-text eviction")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 31, y = 11 } }), nil,
        "unrelated text never becomes a target")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("persisted plain XPointer inside a larger word fails the live boundary check", function()
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["plain:255:alice"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:35", prefix = "M" } } },
    } }
    reset({
        hay = "Malice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    doc.pointer_text["p2:30"] = "Alice"
    doc.range_text["p2:29|p2:30"] = "M"
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 0, "mid-word pointer has no cold fallback")
    TestRunner:eq(#persistence.evictions, 1, "mid-word pointer eviction")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("regex cache entries are ignored and never persisted", function()
    local persistence = { status = "ready", disposition = "valid", terms = {
        ["regex:1:A.*e"] = { outcome = "hits",
            hits = { { start = "p2:30", e = "p2:35" } } },
    } }
    reset({
        hay = "alice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice", "A.*e") }) } },
    })
    local doc = makeDocument("/book.epub", { ["A.*e"] = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    TestRunner:eq(#doc.searches, 1, "regex performs session-native search")
    TestRunner:eq(#persistence.puts, 0, "regex never persisted")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("unavailable, disabled, and rejected persistence still mark via session search", function()
    for _, persistence in ipairs({
        { status = "ready", disposition = "rejected", terms = {} },
        { status = "disabled", disposition = "disabled", terms = {} },
        false,
    }) do
        local fixture = {
            hay = "Alice", persistence = persistence,
            live = { timestamp = 1, progress_decimal = 1,
                entities = { entity("Alice", { term("Alice") }) } },
        }
        reset(fixture)
        local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
        local plugin = makePlugin(doc)
        XrayMarks.sync(plugin); drain()
        TestRunner:eq(#doc.searches, 1, "index-unavailable state keeps session-native marking")
        if persistence and persistence.status == "ready" then
            TestRunner:eq(#(persistence.puts or {}), 1, "rejected cache rebuilds from live demand")
        else
            local index_state = fixture.persistence and fixture.persistence or nil
            local puts = index_state and index_state.puts or {}
            TestRunner:eq(#puts, 0, "disabled/unavailable index persists nothing")
        end
        XrayMarks.teardown(plugin)
    end
end)

TestRunner:test("invalid persisted XPointer is evicted without same-session fallback", function()
    local persistence = { status = "ready", terms = {
        ["plain:255:alice"] = { outcome = "hits",
            hits = { { start = "invalid", e = "also-invalid" } } },
    } }
    reset({
        hay = "Alice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 0, "no fallback search after invalid persisted pointer")
    TestRunner:eq(#persistence.evictions, 1, "eviction count")
    XrayMarks.onPageTurn(plugin, 2)
    drain()
    TestRunner:eq(#doc.searches, 0, "same-session retry remains suppressed")
    XrayMarks.teardown(plugin)
end)

TestRunner:suite("session fencing and failure suppression")
TestRunner:test("stale callbacks, sync, and teardown cannot touch a same-path reopened document", function()
    reset({
        hay = "Alice",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local old_doc = makeDocument("/same.epub", { Alice = { hit(2, 10) } })
    local old_plugin = makePlugin(old_doc)
    XrayMarks.sync(old_plugin)
    drain()
    local old_widget = old_plugin.ui.view.view_modules.koassistant_xray_marks
    XrayMarks.onPageTurn(old_plugin, 2)
    local stale_tick = scheduled[#scheduled]
    local stale_resume = XrayMarks.resumeCallback(old_plugin)
    XrayMarks.teardown(old_plugin)

    local new_doc = makeDocument("/same.epub", { Alice = { hit(2, 20) } })
    local new_plugin = makePlugin(new_doc)
    XrayMarks.sync(new_plugin)

    -- Both eligible and post-close ineligible stale sync paths are fenced.
    XrayMarks.sync(old_plugin)
    old_plugin.ui.document = nil
    XrayMarks.sync(old_plugin)
    XrayMarks.teardown(old_plugin)
    assert(new_plugin.ui.view.view_modules.koassistant_xray_marks,
        "stale public calls must not remove the new view module")

    stale_tick()
    stale_resume()
    TestRunner:eq(#old_doc.searches, 1, "closed document untouched")
    TestRunner:eq(#new_doc.searches, 0, "new document not resumed by stale calls")
    drain()
    TestRunner:eq(#new_doc.searches, 1, "new session scans only its own callback")
    local painted = 0
    old_widget.paintTo(old_widget, { paintRect = function() painted = painted + 1 end })
    TestRunner:eq(painted, 0, "old view widget cannot paint reopened session boxes")
    XrayMarks.teardown(new_plugin)
end)

TestRunner:test("nil, exception, malformed, cap, and invalid pointers are attempted once per session", function()
    local capped = {}
    for i = 1, 2000 do capped[i] = hit(2, i, 1) end
    local persistence = { status = "ready", terms = {} }
    reset({
        hay = "NilTerm ThrowTerm BadTerm CapTerm PointerTerm GoodTerm",
        persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1, entities = {
            entity("Nil", { term("NilTerm") }),
            entity("Throw", { term("ThrowTerm") }),
            entity("Bad", { term("BadTerm") }),
            entity("Cap", { term("CapTerm") }),
            entity("Pointer", { term("PointerTerm") }),
            entity("Available", { term("GoodTerm"), term("ThrowTerm") }),
        } },
    })
    local doc = makeDocument("/book.epub", {
        NilTerm = function() return nil end,
        ThrowTerm = function() error("native search failed") end,
        BadTerm = { { start = false, ["end"] = "p2:1" } },
        CapTerm = capped,
        PointerTerm = { { start = "invalid", ["end"] = "also-invalid" } },
        GoodTerm = { hit(2, 80) },
    })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    TestRunner:eq(#doc.searches, 6, "initial demand count")
    TestRunner:eq(#persistence.puts, 1, "only complete live-mapped outcome persisted")
    TestRunner:eq(persistence.puts[1].key, "plain:255:goodterm", "persisted descriptor")
    local available = XrayMarks.tapTarget(plugin, { pos = { x = 81, y = 11 } })
    TestRunner:eq(available, "GoodTerm", "independent valid handle remains available")

    XrayMarks.onPageTurn(plugin, 2)
    drain()
    TestRunner:eq(#doc.searches, 6, "failed outcomes are session-suppressed")
    XrayMarks.teardown(plugin)
end)

TestRunner:suite("presentation withdrawal and lifecycle")
TestRunner:test("pending identity verification resumes after scroll returns to page mode", function()
    local persistence = { status = "pending", terms = {} }
    reset({
        hay = "Alice", persistence = persistence,
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin); drain()
    plugin.ui.view.view_mode = "scroll"
    XrayMarks.onViewModeChanged(plugin)
    assert(persistence.paused, "scroll pauses verification")
    plugin.ui.view.view_mode = "page"
    XrayMarks.onViewModeChanged(plugin)
    TestRunner:eq(persistence.resume_count, 1, "page mode resumes verification")
    persistence.status = "ready"
    persistence.on_ready(); drain()
    TestRunner:eq(#doc.searches, 1, "cold scan resumes after verification")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("search, scroll, suspend, partial rerender, and close remove stale targets", function()
    reset({
        hay = "Alice",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    assert(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), "target prepared")
    local function expectWithdrawal(label, action)
        dirty = 0
        action()
        assert(dirty > 0, label .. " must request its own redraw")
        TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), nil, label)
    end

    plugin.ui.search._koassistant_search_session = true
    expectWithdrawal("search", function() XrayMarks.pause(plugin) end)
    plugin.ui.search._koassistant_search_session = nil
    XrayMarks.resume(plugin)
    drain()

    plugin.ui.view.view_mode = "scroll"
    expectWithdrawal("scroll", function() XrayMarks.onViewModeChanged(plugin) end)
    plugin.ui.view.view_mode = "page"
    XrayMarks.onViewModeChanged(plugin)
    drain()

    expectWithdrawal("suspend", function() XrayMarks.pause(plugin, true) end)
    XrayMarks.resume(plugin)
    drain()

    expectWithdrawal("partial rerender", function() XrayMarks.onLayoutChanged(plugin, true) end)
    XrayMarks.onPageTurn(plugin, 2)
    TestRunner:eq(#scheduled, 0, "partial layout does not publish geometry")
    XrayMarks.onLayoutChanged(plugin, false)
    drain()
    TestRunner:eq(#doc.searches, 1, "full rerender remaps without search")

    expectWithdrawal("close", function() XrayMarks.teardown(plugin) end)
end)

TestRunner:test("disable and scan error each withdraw targets and request redraw", function()
    reset({
        hay = "Alice",
        live = { timestamp = 1, progress_decimal = 1,
            entities = { entity("Alice", { term("Alice") }) } },
    })
    local doc = makeDocument("/book.epub", { Alice = { hit(2, 10) } })
    local plugin = makePlugin(doc)
    XrayMarks.sync(plugin)
    drain()
    fixture.marking = { enabled = false, tap = true, density = "first", families = "all" }
    dirty = 0
    XrayMarks.sync(plugin)
    assert(dirty > 0, "disable must request its own redraw")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), nil, "disable")

    fixture.marking = nil
    XrayMarks.sync(plugin)
    drain()
    assert(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), "target restored")
    fixture.dirty_error_once = true
    dirty = 0
    XrayMarks.onLayoutChanged(plugin, false)
    -- Layout withdrawal itself is immediate; isolate the later scan failure.
    dirty = 0
    drain()
    assert(dirty > 0, "scan error must withdraw its just-published boxes")
    TestRunner:eq(XrayMarks.tapTarget(plugin, { pos = { x = 11, y = 11 } }), nil, "scan error")
    XrayMarks.teardown(plugin)
end)

TestRunner:test("main.lua wires verified KOReader lifecycle event names", function()
    local f = assert(io.open(PLUGIN_DIR .. "/main.lua", "rb"))
    local source = f:read("*a"); f:close()
    for _, needle in ipairs({
        "function AskGPT:onDocumentRerendered()",
        "function AskGPT:onDocumentPartiallyRerendered()",
        "function AskGPT:onChangeViewMode()",
        "function AskGPT:onSuspend()",
        "function AskGPT:onResume()",
        "marks.pause(marks_self)",
        "local resume_marks = marks.resumeCallback(marks_self)",
    }) do
        assert(source:find(needle, 1, true), "missing lifecycle seam: " .. needle)
    end
end)

if active_plugin then pcall(XrayMarks.teardown, active_plugin) end
for _, name in ipairs(mocked_names) do package.loaded[name] = saved_modules[name][1] end

print(string.format("\n  X-Ray marks: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
