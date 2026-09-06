-- Behavioral tests for the real persistent passive-marking index module.

local function setupPaths()
    local source = debug.getinfo(1, "S").source:match("@?(.*)")
    local unit_dir = source:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({ plugin_dir .. "/?.lua", tests_dir .. "/?.lua", package.path }, ";")
end
setupPaths()

local mocked = { "ui/uimanager", "libs/libkoreader-lfs", "docsettings",
    "koassistant_storage_registry", "version", "ffi/sha2", "util", "json",
    "koassistant_xray_marks_index" }
local saved = {}
for _, name in ipairs(mocked) do saved[name] = package.loaded[name] end
local ok_json, json = pcall(require, "json")
if not ok_json then json = require("dkjson"); package.loaded["json"] = json end

local scheduled, cancelled = {}, {}
local UIManager = {}
function UIManager:scheduleIn(delay, callback)
    scheduled[#scheduled + 1] = { delay = delay, callback = callback }
end
function UIManager:unschedule(callback) cancelled[callback] = true end
package.loaded["ui/uimanager"] = UIManager

local root = "/tmp/koassistant_xray_marks_index_test_" .. tostring(os.time())
os.execute(string.format("rm -rf %q && mkdir -p %q", root, root))
local inheritedRename = os.rename
local fail_rename = false
local function testRename(from, to)
    if fail_rename then return nil, "simulated rename failure" end
    -- Exercise the host's real same-directory rename for successful
    -- publications; only the explicit fault path is mocked.
    return inheritedRename(from, to)
end
-- luacheck: push ignore 122
os.rename = testRename
-- luacheck: pop

local book = root .. "/book.epub"
local sidecar = root .. "/koassistant_xray_marks_index.json"
local temp_sidecar = sidecar .. ".tmp"
local sentinel = root .. "/must_survive"
local book_mtime = 100
local function sizeOf(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end"); file:close(); return size
end
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path)
        local size = sizeOf(path)
        if not size then return nil end
        return { mode = "file", size = size,
            modification = path == book and book_mtime or 200 }
    end,
}
package.loaded["docsettings"] = { getSidecarDir = function() return root end }
local migrations = {}
package.loaded["koassistant_storage_registry"] = {
    migrateSidecarFile = function(_file, _path, name)
        migrations[#migrations + 1] = name
        return false
    end,
}
local revision = "v2026.07.1-1-gabcdef01"
package.loaded["version"] = { getCurrentRevision = function() return revision end }

local feed_sizes = {}
package.loaded["ffi/sha2"] = {
    sha256 = function()
        local chunks = {}
        return function(chunk)
            if chunk ~= nil then
                feed_sizes[#feed_sizes + 1] = #chunk
                chunks[#chunks + 1] = chunk
                return
            end
            local data = table.concat(chunks)
            local nibble = (#data + (data:byte(1) or 0)) % 16
            return string.rep(string.format("%x", nibble), 64)
        end
    end,
}

local fail_tmp_write, short_tmp_write, write_count, written_bytes = false, false, 0, 0
local partial_md5 = "0123456789abcdef0123456789abcdef"
local Util = {}
function Util.makePath(path) os.execute(string.format("mkdir -p %q", path)) end
function Util.partialMD5() return partial_md5 end
function Util.writeToFile(data, path)
    if fail_tmp_write and path:match("%.tmp$") then return nil, "simulated write failure" end
    write_count, written_bytes = write_count + 1, written_bytes + #data
    local file = assert(io.open(path, "wb"))
    file:write(short_tmp_write and data:sub(1, math.floor(#data / 2)) or data)
    file:close()
    return true
end
package.loaded["util"] = Util
package.loaded["koassistant_xray_marks_index"] = nil
local Index = require("koassistant_xray_marks_index")

local TestRunner = { passed = 0, failed = 0 }
function TestRunner:suite(name) print("\n  [" .. name .. "]") end
function TestRunner:test(name, fn)
    local ok, err = pcall(fn)
    if ok then self.passed = self.passed + 1; print("    ✓ " .. name)
    else self.failed = self.failed + 1; print("    ✗ " .. name); print("      Error: " .. tostring(err)) end
end
function TestRunner:eq(actual, expected, label)
    if actual ~= expected then error(string.format("%s: expected %s, got %s",
        label or "value", tostring(expected), tostring(actual))) end
end

local owner, rendering_hash = true, 424242
local document = { file = book, provider = "crengine", mod_time = book_mtime }
function document:getDocumentFormat() return "epub" end
function document:getDocumentRenderingHash() return rendering_hash end
local doc_settings = { readSetting = function(_self, key)
    if key == "cre_dom_version" then return 20200824 end
    if key == "partial_md5_checksum" then return "0123456789abcdef0123456789abcdef" end
end }
local function writeRaw(path, data)
    local file = assert(io.open(path, "wb")); file:write(data); file:close()
end
local function copyFile(from, to)
    local input = assert(io.open(from, "rb")); local data = input:read("*a"); input:close()
    writeRaw(to, data); return data
end
local function resetQueue()
    scheduled, cancelled, feed_sizes = {}, {}, {}
    write_count, written_bytes = 0, 0
end
local function runNext()
    local item = table.remove(scheduled, 1)
    if not item then return false end
    if not cancelled[item.callback] then item.callback(); return true end
    return false
end
local function drain(limit)
    local count = 0
    while #scheduled > 0 do
        if runNext() then count = count + 1 end
        if count > (limit or 100) then error("callback loop") end
    end
    return count
end
local function start(on_ready)
    return Index.start {
        file = book, document = document, doc_settings = doc_settings,
        dom_open_identity = rendering_hash,
        is_owner = function() return owner end,
        on_ready = on_ready or function() end,
    }
end

writeRaw(book, string.rep("A", Index.HASH_CHUNK_BYTES * 2 + 123))
os.remove(sidecar); os.remove(temp_sidecar)

TestRunner:suite("identity hashing, persistence, and warm reuse")
local valid_primary
TestRunner:test("each scheduled hash tick feeds at most one bounded chunk", function()
    resetQueue(); owner = true
    local ready = 0
    local state = assert(start(function() ready = ready + 1 end))
    TestRunner:eq(state.status, "pending", "initial status")
    TestRunner:eq(#feed_sizes, 0, "no eager SHA work")
    local prior = 0
    while state.status == "pending" do
        assert(runNext(), "pending hash must own a callback")
        assert(#feed_sizes - prior <= 1, "one SHA feed maximum per callback")
        prior = #feed_sizes
    end
    TestRunner:eq(state.status, "ready", "verified status")
    TestRunner:eq(ready, 1, "ready callback")
    for _, size in ipairs(feed_sizes) do assert(size <= Index.HASH_CHUNK_BYTES, "bounded SHA feed") end
    Index.close(state)
end)

TestRunner:test("trailing debounce batches repeated puts into one bounded publication", function()
    resetQueue(); local state = assert(start()); drain()
    assert(Index.put(state, "plain:255:alice", "hits", { { start = "p2:10", e = "p2:15" } }))
    local first_flush = scheduled[#scheduled]
    assert(first_flush.delay >= 10, "flush uses an idle-scale delay")
    assert(Index.put(state, "plain:255:bob", "hits", { { start = "p3:10", e = "p3:13" } }))
    assert(cancelled[first_flush.callback], "later put postpones the prior flush")
    local second_flush = scheduled[#scheduled]
    assert(second_flush.callback ~= first_flush.callback, "debounce callback replaced")
    assert(Index.put(state, "plain:255:carol", "hits", { { start = "p4:10", e = "p4:15" } }))
    assert(cancelled[second_flush.callback], "trailing edge moves again")
    TestRunner:eq(write_count, 0, "no leading-edge write")
    drain()
    TestRunner:eq(write_count, 1, "one trailing-edge write")
    assert(written_bytes <= Index.MAX_FILE_BYTES, "bounded serialized bytes")
    assert(sizeOf(sidecar) and not sizeOf(temp_sidecar), "primary atomically published")
    assert(Index.put(state, "plain:255:dave", "hits", { { start = "p5:1", e = "p5:5" } }))
    drain()
    TestRunner:eq(write_count, 2, "second idle batch writes once")
    assert(not sizeOf(sidecar .. ".old") and not sizeOf(sidecar .. ".old.tmp")
        and not sizeOf(temp_sidecar), "no unregistered recovery companions")
    local decoded = json.decode(copyFile(sidecar, sidecar .. ".saved"))
    assert(decoded.terms["plain:255:alice"] and decoded.terms["plain:255:carol"], "all terms published")
    valid_primary = copyFile(sidecar, sidecar .. ".valid")
    Index.close(state)
end)

TestRunner:test("warm reopen exposes hits only after full identity succeeds", function()
    resetQueue(); local state = assert(start())
    assert(Index.get(state, "plain:255:alice") == nil, "pending state exposes nothing")
    drain()
    local entry = assert(Index.get(state, "plain:255:alice"))
    TestRunner:eq(entry.hits[1].start, "p2:10", "warm pointer")
    Index.close(state)
end)

TestRunner:test("revision or opened-DOM/file identity mismatch cannot admit persistence", function()
    writeRaw(sidecar, valid_primary); os.remove(temp_sidecar)
    resetQueue(); revision = "v2026.07.1-2-gdifferent"
    local state = assert(start()); drain()
    TestRunner:eq(state.disposition, "rejected", "revision disposition")
    assert(Index.get(state, "plain:255:alice") == nil, "mismatched cache never exposed")
    assert(Index.allowColdSearch(state), "marking keeps its session-native search")
    assert(not sizeOf(sidecar), "mismatched primary removed")
    Index.close(state); revision = "v2026.07.1-1-gabcdef01"

    partial_md5 = "ffffffffffffffffffffffffffffffff"
    local unavailable_path, mismatch = start()
    assert(unavailable_path == nil and mismatch == "disabled",
        "disk no longer matches open-time partial source identity")
    partial_md5 = "0123456789abcdef0123456789abcdef"

    book_mtime = book_mtime + 1
    local stale_dom, stale_reason = start()
    assert(stale_dom == nil and stale_reason == "disabled",
        "open DOM modification time must match the hashed snapshot")
    book_mtime = book_mtime - 1

    rendering_hash = 515151
    local missing, reason = Index.start {
        file = book, document = document, doc_settings = doc_settings,
        dom_open_identity = 424242, is_owner = function() return true end,
    }
    assert(missing == nil and reason == "disabled", "changed live DOM fails closed")
    rendering_hash = 424242
end)

TestRunner:suite("data-only parsing, rejection, and recovery")
TestRunner:test("executable and looping Lua payloads are inert rejected JSON", function()
    writeRaw(sentinel, "present")
    for _, payload in ipairs({
        "os.remove(" .. string.format("%q", sentinel) .. ")",
        "while true do end",
        "return { schema = 2 }",
    }) do
        writeRaw(sidecar, payload); os.remove(temp_sidecar)
        resetQueue(); local state = assert(start()); drain()
        TestRunner:eq(state.disposition, "rejected", "payload disposition")
        assert(sizeOf(sentinel), "payload must never execute")
        assert(not Index.get(state, "plain:255:alice"), "rejected cache never exposed")
        assert(Index.allowColdSearch(state), "marking keeps its session-native search")
        Index.close(state)
    end
end)

TestRunner:test("truncated and oversized files are removed and quarantined", function()
    for _, payload in ipairs({ "{\"schema\":2", string.rep("x", Index.MAX_FILE_BYTES + 1) }) do
        writeRaw(sidecar, payload); os.remove(temp_sidecar)
        resetQueue(); local state = assert(start()); drain()
        TestRunner:eq(state.disposition, "rejected", "corrupt disposition")
        assert(not sizeOf(sidecar), "bad cache removed")
        Index.close(state)
    end
end)

TestRunner:test("LuaJSON-style callable-table json modules are accepted", function()
    local real = json
    local decode_table = setmetatable({}, { __call = function(_self, ...) return real.decode(...) end })
    local encode_table = setmetatable({}, { __call = function(_self, ...) return real.encode(...) end })
    package.loaded["json"] = { decode = decode_table, encode = encode_table }
    writeRaw(sidecar, valid_primary); os.remove(temp_sidecar)
    resetQueue(); local state = assert(start()); drain()
    TestRunner:eq(state.disposition, "valid", "callable-table decode admitted")
    assert(Index.get(state, "plain:255:alice"), "warm entry served via callable-table json")
    assert(Index.put(state, "plain:255:bob", "hits", { { start = "p3:1", e = "p3:4" } }))
    drain()
    assert(sizeOf(sidecar), "primary written via callable-table encode")
    local data = real.decode(copyFile(sidecar, sidecar .. ".check"))
    assert(data.terms["plain:255:bob"], "callable encode produced readable JSON")
    Index.close(state)
    package.loaded["json"] = real
end)

TestRunner:test("obsolete executable and predecessor companions are removed, never loaded", function()
    os.remove(sidecar); os.remove(temp_sidecar)
    writeRaw(sentinel, "present")
    for _, name in ipairs(Index.OBSOLETE_FILENAMES) do
        writeRaw(root .. "/" .. name,
            "os.remove(" .. string.format("%q", sentinel) .. ")")
    end
    resetQueue(); local state = assert(start()); drain()
    TestRunner:eq(state.disposition, "absent", "obsolete-only disposition")
    assert(sizeOf(sentinel), "obsolete Lua must remain inert")
    for _, name in ipairs(Index.OBSOLETE_FILENAMES) do
        assert(not sizeOf(root .. "/" .. name), "obsolete companion cleanup: " .. name)
    end
    Index.close(state)
end)

TestRunner:test("verified temp recovers only when no valid primary survives", function()
    os.remove(sidecar); writeRaw(temp_sidecar, valid_primary)
    resetQueue(); local state = assert(start()); drain()
    TestRunner:eq(state.disposition, "valid", "recovery disposition")
    assert(Index.get(state, "plain:255:alice"), "temp contents recovered")
    assert(sizeOf(sidecar) and not sizeOf(temp_sidecar), "temp promoted")
    Index.close(state)
end)

TestRunner:test("failed promotion of a verified temp stays read-only and never cold-searches", function()
    os.remove(sidecar); writeRaw(temp_sidecar, valid_primary)
    resetQueue(); local state = assert(start())
    fail_rename = true
    drain()
    fail_rename = false
    TestRunner:eq(state.disposition, "recovered_read_only", "read-only recovery disposition")
    assert(not Index.allowColdSearch(state), "recovery rename failure suppresses cold fallback")
    assert(Index.get(state, "plain:255:alice"), "verified temp contents stay usable")
    assert(sizeOf(temp_sidecar), "complete temp retained for a later recovery")
    assert(not sizeOf(sidecar), "nothing published over the failed rename")
    assert(state.write_disabled, "write circuit breaker engaged")
    assert(not Index.put(state, "plain:255:new", "hits",
        { { start = "p7:1", e = "p7:5" } }), "no writes from a read-only recovery")
    Index.close(state)
end)

TestRunner:test("short temp write preserves the previous atomic primary", function()
    writeRaw(sidecar, valid_primary); os.remove(temp_sidecar)
    local before = copyFile(sidecar, sidecar .. ".before-short")
    resetQueue(); local state = assert(start()); drain()
    assert(Index.put(state, "plain:255:erin", "hits", { { start = "p6:1", e = "p6:5" } }))
    short_tmp_write = true; drain(); short_tmp_write = false
    TestRunner:eq(copyFile(sidecar, sidecar .. ".after-short"), before,
        "short write must not replace primary")
    assert(not sizeOf(temp_sidecar) and state.write_disabled, "short temp rejected")
    Index.close(state)
end)

TestRunner:test("rename failure preserves primary, leaves bounded recovery temp, and does not loop", function()
    writeRaw(sidecar, valid_primary); os.remove(temp_sidecar)
    local before = copyFile(sidecar, sidecar .. ".before")
    resetQueue(); local state = assert(start()); drain()
    assert(Index.put(state, "plain:255:dave", "hits", { { start = "p5:1", e = "p5:5" } }))
    fail_rename = true
    local callbacks = drain()
    fail_rename = false
    TestRunner:eq(callbacks, 1, "single write attempt")
    TestRunner:eq(copyFile(sidecar, sidecar .. ".after"), before, "previous primary preserved")
    assert(sizeOf(temp_sidecar) and sizeOf(temp_sidecar) <= Index.MAX_FILE_BYTES, "recoverable temp retained")
    assert(state.write_disabled, "writer circuit breaker")
    Index.close(state)
end)

TestRunner:test("empty outcomes and malformed bounds are never persistent", function()
    os.remove(temp_sidecar); writeRaw(sidecar, valid_primary)
    resetQueue(); local state = assert(start()); drain()
    assert(not Index.put(state, "plain:255:none", "empty", {}), "empty stays session-only")
    local base = { schema = Index.SCHEMA, identity = state.identity,
        search = { schema = Index.SEARCH_SCHEMA, cap = Index.SEARCH_CAP,
            plain_flags = Index.PLAIN_FLAGS, regex_flags = Index.REGEX_FLAGS,
            boundary_schema = 1 }, terms = {} }
    assert(Index._validateCache(base, state.identity), "valid empty index")
    base.terms[string.rep("q", Index.MAX_QUERY_KEY_BYTES + 1)] = {
        outcome = "hits", hits = { { start = "p1:1", e = "p1:2" } } }
    assert(not Index._validateCache(base, state.identity), "query key bound")
    Index.close(state)
end)

TestRunner:suite("cancellation and mutation fencing")
TestRunner:test("close cancels an in-progress hash before SHA work", function()
    resetQueue(); local state = assert(start()); Index.close(state); drain()
    TestRunner:eq(#feed_sizes, 0, "cancelled feeder calls")
end)

TestRunner:test("file or live-DOM mutation during hashing disables persistence", function()
    resetQueue(); local state = assert(start())
    assert(runNext()); book_mtime = book_mtime + 1; drain()
    TestRunner:eq(state.status, "disabled", "file mutation status")
    assert(Index.allowColdSearch(state), "hash abort never disables session-native marking")
    assert(not Index.get(state, "plain:255:alice"), "unverified cache never exposed")
    Index.close(state); book_mtime = book_mtime - 1

    resetQueue(); state = assert(start()); assert(runNext()); rendering_hash = 616161; drain()
    TestRunner:eq(state.status, "disabled", "DOM mutation status")
    rendering_hash = 424242; Index.close(state)
end)

os.execute(string.format("rm -rf %q", root))
-- luacheck: push ignore 122
os.rename = inheritedRename
-- luacheck: pop
for _, name in ipairs(mocked) do package.loaded[name] = saved[name] end
print(string.format("\n  X-Ray marks index: %d passed, %d failed", TestRunner.passed, TestRunner.failed))
return TestRunner.failed == 0
