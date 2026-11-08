#!/usr/bin/env lua
-- tests/tmmeta_test.lua — unit tests for tmmeta.lua, the SPEC-TASKMARK-04
-- §9.1 flat `key: value` configuration reader.

local script_dir = (arg[0] or "./tests/tmmeta_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmmeta = require("tmmeta")

local passed, failed = 0, 0

local function check(group, name, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s: %s", group, name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s: %s%s", group, name, detail and (" -- " .. detail) or ""))
    end
end

-- ── parse_lines ──────────────────────────────────────────────────────────

do
    local tbl = tmmeta.parse_lines({ "project: demo", "status: Active" })
    check("parse_lines", "basic key/value parsing", tbl.project == "demo" and tbl.status == "Active")
end

do
    local tbl = tmmeta.parse_lines({ "note: '  quoted  '" })
    check("parse_lines", "trailing whitespace stripped before quote check", tbl.note == "  quoted  ")
end

do
    local tbl = tmmeta.parse_lines({ "a: 'single'", 'b: "double"', "c: 'mismatched\"" })
    check("parse_lines", "single-quoted value unwrapped", tbl.a == "single")
    check("parse_lines", "double-quoted value unwrapped", tbl.b == "double")
    check("parse_lines", "mismatched quotes left intact", tbl.c == "'mismatched\"")
end

do
    local tbl = tmmeta.parse_lines({ "key: value   " })
    check("parse_lines", "trailing whitespace stripped from unquoted value", tbl.key == "value")
end

do
    local tbl, err, line = tmmeta.parse_lines({ "" })
    check("parse_lines", "blank line is an error without relaxed", tbl == nil and err ~= nil)
    check("parse_lines", "reports the offending line index", line == 1)
end

do
    local tbl, err = tmmeta.parse_lines({ "# a comment" })
    check("parse_lines", "'#'-led line is an error without relaxed", tbl == nil and err ~= nil)
end

do
    local tbl = tmmeta.parse_lines({ "", "  # comment", "key: value", "" }, { relaxed = true })
    check("parse_lines", "relaxed skips blank and '#'-led lines", tbl.key == "value")
end

do
    local tbl, err = tmmeta.parse_lines({ "no colon here" })
    check("parse_lines", "line without valid key: value grammar is an error", tbl == nil and err ~= nil)
end

do
    local tbl, err = tmmeta.parse_lines({ "key:no space" })
    check("parse_lines", "missing space after colon is an error", tbl == nil and err ~= nil)
end

do
    local tbl, err = tmmeta.parse_lines({ "key: one", "key: two" })
    check("parse_lines", "duplicate key is an error", tbl == nil and err ~= nil)
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
