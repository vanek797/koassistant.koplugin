-- Unit tests for the shared byte-budget cuts in koassistant_scope_resolver.lua
-- (utf8Head / utf8Tail / utf8TrimTail / utf8TrimHead).

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

local ScopeResolver = require("koassistant_scope_resolver")
local TestRunner = require("test_runner"):new()

local A3 = "東"        -- 3 bytes
local A4 = "😀"        -- 4 bytes
local A2 = "é"         -- 2 bytes

TestRunner:test("utf8Head: within budget returns the string unchanged", function()
    TestRunner:assertEqual(ScopeResolver.utf8Head("abc", 3), "abc", "exact fit")
    TestRunner:assertEqual(ScopeResolver.utf8Head(A3 .. A3, 6), A3 .. A3, "exact multi-byte fit")
end)

TestRunner:test("utf8Head: a cut inside a character drops the partial character", function()
    TestRunner:assertEqual(ScopeResolver.utf8Head(A3 .. A3, 4), A3, "3-byte: 1 stray byte dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Head(A3 .. A3, 5), A3, "3-byte: 2 stray bytes dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Head(A4 .. A4, 7), A4, "4-byte: 3 stray bytes dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Head("ab" .. A2, 3), "ab", "2-byte after ASCII")
    TestRunner:assertEqual(ScopeResolver.utf8Head("abc" .. A3, 3), "abc", "ASCII boundary untouched")
end)

TestRunner:test("utf8Tail: a cut inside a character drops the leading continuation bytes", function()
    TestRunner:assertEqual(ScopeResolver.utf8Tail(A3 .. A3, 4), A3, "3-byte: 1 stray byte dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Tail(A3 .. A3, 5), A3, "3-byte: 2 stray bytes dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Tail(A4 .. "x", 2), "x", "4-byte: stray tail dropped")
    TestRunner:assertEqual(ScopeResolver.utf8Tail(A3 .. "abc", 3), "abc", "ASCII boundary untouched")
    TestRunner:assertEqual(ScopeResolver.utf8Tail("ab", 5), "ab", "within budget unchanged")
end)

TestRunner:test("trims: ASCII and malformed input pass through", function()
    TestRunner:assertEqual(ScopeResolver.utf8TrimTail("abc"), "abc", "ASCII tail")
    TestRunner:assertEqual(ScopeResolver.utf8TrimTail(""), "", "empty")
    TestRunner:assertEqual(ScopeResolver.utf8TrimTail("a\128\128"), "a\128\128", "stray continuations after ASCII kept")
    TestRunner:assertEqual(ScopeResolver.utf8TrimHead("abc"), "abc", "ASCII head")
    TestRunner:assertEqual(ScopeResolver.utf8TrimHead("\128\128"), "", "only continuations: emptied")
end)

return TestRunner:summary()
