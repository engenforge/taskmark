#!/usr/bin/env lua
-- tests/tmmeta_test.lua — unit tests for tmmeta.lua (SPEC-TASKMARK-03
-- §2.2.1 flat `key: value` reader/writer).

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

-- ── split_frontmatter ────────────────────────────────────────────────────

do
    local lines = { "---", "project: demo", "status: Active", "---", "# Body" }
    local tbl, body_start, span = tmmeta.split_frontmatter(lines)
    check("split_frontmatter", "parses the enclosed block", tbl.project == "demo" and tbl.status == "Active")
    check("split_frontmatter", "body_start_index points past closing delimiter", body_start == 5)
    check("split_frontmatter", "raw_span excludes both delimiters", #span == 2 and span[1] == "project: demo")
end

do
    local tbl, reason = tmmeta.split_frontmatter({ "project: demo", "---" })
    check("split_frontmatter", "missing opening delimiter", tbl == nil and reason == "missing")
end

do
    local tbl, reason = tmmeta.split_frontmatter({ "---", "project: demo" })
    check("split_frontmatter", "no closing delimiter", tbl == nil and reason == "unterminated")
end

do
    local tbl, reason = tmmeta.split_frontmatter({ "---", "not a valid line", "---" })
    check("split_frontmatter", "invalid line inside the block", tbl == nil and reason == "bad_line")
end

-- ── render ───────────────────────────────────────────────────────────────

do
    local tbl = { project = "demo", status = "Active", sprint = "2026-S3", date = "2026-07-07" }
    local order = { "project", "status", "sprint", "date" }
    local lines = tmmeta.render(tbl, order)
    check("render", "orders keys per `order`", table.concat(lines, "\n") ==
        "project: demo\nstatus: Active\nsprint: 2026-S3\ndate: 2026-07-07")
end

do
    local tbl = { z = "1", a = "2", m = "3" }
    local lines = tmmeta.render(tbl, {})
    check("render", "keys not in order are sorted lexicographically", table.concat(lines, "\n") ==
        "a: 2\nm: 3\nz: 1")
end

do
    local tbl = { a = "1", b = "2" }
    local lines = tmmeta.render(tbl, { "a", "missing" })
    check("render", "order entries absent from tbl are skipped", table.concat(lines, "\n") ==
        "a: 1\nb: 2")
end

-- ── set_date ─────────────────────────────────────────────────────────────

do
    local lines = {
        "---",
        "project: demo",
        "date: 2026-01-01",
        "status: Active",
        "---",
        "",
        "# Body text unaffected",
    }
    local out = tmmeta.set_date(lines, "2026-09-01")
    check("set_date", "date value replaced", out[3] == "date: 2026-09-01")
    check("set_date", "delimiters and other frontmatter lines byte-identical",
        out[1] == "---" and out[2] == "project: demo" and out[4] == "status: Active" and out[5] == "---")
    check("set_date", "body lines byte-identical", out[6] == "" and out[7] == "# Body text unaffected")
    check("set_date", "original array untouched", lines[3] == "date: 2026-01-01")
end

do
    local tbl, reason = tmmeta.set_date({ "no frontmatter here" }, "2026-09-01")
    check("set_date", "propagates split_frontmatter failure reason", tbl == nil and reason == "missing")
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
