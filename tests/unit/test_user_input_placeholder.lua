-- {user_input} (2026-09-07, parity audit F117): a prompt that names the
-- placeholder gets the typed text IN PLACE; a prompt that does not keeps the
-- "[Additional user input]" tail. The action manager treated the placeholder as
-- "needs typed input" for years while nothing substituted it.
--
-- Run: lua tests/unit/test_user_input_placeholder.lua  (or lua tests/run_tests.lua --unit)

local function setupPaths()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@?(.*)")
    local unit_dir = script_path:match("(.+)/[^/]+$") or "."
    local tests_dir = unit_dir:match("(.+)/[^/]+$") or "."
    local plugin_dir = tests_dir:match("(.+)/[^/]+$") or "."
    package.path = table.concat({
        plugin_dir .. "/?.lua",
        plugin_dir .. "/koassistant_api/?.lua",
        tests_dir .. "/?.lua",
        tests_dir .. "/lib/?.lua",
        package.path,
    }, ";")
end
setupPaths()
require("mock_koreader")
local MessageBuilder = require("message_builder")
local TestRunner = require("test_runner"):new()

local function has(s, needle) return s:find(needle, 1, true) ~= nil end

TestRunner:test("placeholder present: typed text lands in place, no tail block", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Answer this about the book: {user_input}. Be brief." },
        context = "general",
        data = { additional_input = "who is the narrator" },
    })
    TestRunner:assertTrue(has(result, "Answer this about the book: who is the narrator. Be brief."), "substituted")
    TestRunner:assertFalse(has(result, "{user_input}"), "no literal braces")
    TestRunner:assertFalse(has(result, "[Additional user input]"), "no tail block")
end)

TestRunner:test("placeholder absent: the tail block still carries the typed text", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Summarize." },
        context = "general",
        data = { additional_input = "focus on chapter two" },
    })
    TestRunner:assertTrue(has(result, "[Additional user input]"), "tail block")
    TestRunner:assertTrue(has(result, "focus on chapter two"), "typed text")
end)

TestRunner:test("placeholder present but nothing typed: braces stay (the manager hides such actions from tap-only menus)", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "Question: {user_input}" },
        context = "general",
        data = {},
    })
    TestRunner:assertTrue(has(result, "{user_input}"), "left as written")
end)

TestRunner:test("highlight context: typed text plus the selection", function()
    local result = MessageBuilder.build({
        prompt = { prompt = "About the selection, {user_input}" },
        context = "highlight",
        data = { highlighted_text = "the green light", additional_input = "explain the symbol" },
    })
    TestRunner:assertTrue(has(result, "About the selection, explain the symbol"), "substituted")
    TestRunner:assertTrue(has(result, "the green light"), "selection kept")
    TestRunner:assertFalse(has(result, "[Additional user input]"), "no tail block")
end)

return TestRunner:summary()
