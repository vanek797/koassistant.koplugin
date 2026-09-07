-- Version parsing and ordering in the update checker (parity audit F098,
-- 2026-09-07). The maintainer's tags are three-part; rc tags offered over OTA as
-- betas make the pre-release order load-bearing: rc.11 must sort ABOVE rc.9, a
-- two-part tag must still count, and a release must beat its own rc.
--
-- Run: lua tests/unit/test_update_versions.lua  (or lua tests/run_tests.lua --unit)

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
local UpdateChecker = require("koassistant_update_checker")
local TestRunner = require("test_runner"):new()

local cmp, parse = UpdateChecker.compareVersions, UpdateChecker.parseVersion

TestRunner:test("parse: one to three components, v prefix, build metadata", function()
    local v = parse("1.2.3-rc.1+build.7")
    TestRunner:assertEqual(v.major .. "." .. v.minor .. "." .. v.patch, "1.2.3", "core")
    TestRunner:assertEqual(v.prerelease, "rc.1", "pre-release without build metadata")
    TestRunner:assertEqual(parse("2").patch, 0, "one component pads")
    TestRunner:assertEqual(parse("2.1").minor, 1, "two components")
    TestRunner:assertEqual(parse("v0.22.0").major, 0, "v prefix")
    TestRunner:assertEqual(parse("0.22.0").prerelease, nil, "no pre-release")
end)

TestRunner:test("parse: rejects junk", function()
    for _idx, bad in ipairs({ "abc", "1.2.3.4", "1..2", ".1", "1.", "", "1.x.2" }) do
        TestRunner:assertEqual(parse(bad), nil, "rejects " .. bad)
    end
    TestRunner:assertEqual(parse(nil), nil, "nil")
end)

local ORDERED = {  -- oldest to newest
    "0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
    "1.0.0-rc.1", "1.0.0-rc.9", "1.0.0-rc.11", "1.0.0", "1.0.1", "1.1", "2.0.0-rc.1", "2", "2.1",
}

TestRunner:test("order: every neighbour pair is ascending (rc.11 above rc.9, two-part tags in place)", function()
    for i = 1, #ORDERED - 1 do
        TestRunner:assertEqual(cmp(ORDERED[i], ORDERED[i + 1]), -1, ORDERED[i] .. " < " .. ORDERED[i + 1])
        TestRunner:assertEqual(cmp(ORDERED[i + 1], ORDERED[i]), 1, ORDERED[i + 1] .. " > " .. ORDERED[i])
    end
end)

TestRunner:test("order: equal forms", function()
    TestRunner:assertEqual(cmp("2", "2.0.0"), 0, "padded equal")
    TestRunner:assertEqual(cmp("v1.0.0", "1.0.0"), 0, "v prefix equal")
    TestRunner:assertEqual(cmp("1.0.0-rc.1", "1.0.0-rc.1"), 0, "same pre-release")
    TestRunner:assertEqual(cmp("junk", "1.0.0"), 0, "unparseable = no claim")
end)

TestRunner:test("order: a dev build is offered its own release and its rc", function()
    TestRunner:assertEqual(cmp("0.22.0-dev", "0.22.0"), -1, "release beats dev")
    TestRunner:assertEqual(cmp("0.22.0-dev", "0.22.0-rc.1"), -1, "rc beats dev (d < r)")
    TestRunner:assertEqual(cmp("0.22.0", "0.22.0-rc.3"), 1, "a release never downgrades to its rc")
end)

return TestRunner:summary()
