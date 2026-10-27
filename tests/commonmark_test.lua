#!/usr/bin/env lua
-- tests/commonmark_test.lua — the CommonMark conformance oracle.
--
-- SPEC-TASKMARK-03 §1.2 claims every conforming document is a strict
-- CommonMark subset that renders correctly and legibly in any CommonMark
-- renderer. The runtime does not use a CommonMark parser (tmscan reads
-- Taskmark's own fixed grammar directly), so that claim needs an
-- independent implementation to check it against. This is the only file
-- in the project permitted to load cmark.so.

local script_dir = (arg[0] or "./tests/commonmark_test.lua"):match("^(.*)/[^/]+$") or "."
package.path  = script_dir .. "/../src/?.lua;" .. package.path
package.cpath = script_dir .. "/../build/?.so;" .. package.cpath

local cmark  = require("cmark")
local tmmeta = require("tmmeta")
local tmscan = require("tmscan")

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

-- ── AST helpers ──────────────────────────────────────────────────────────

local function collect(doc, wanted_type)
    local nodes = {}
    for cur, entering in cmark.walk(doc) do
        if entering and cmark.node_get_type(cur) == wanted_type then
            nodes[#nodes + 1] = cur
        end
    end
    return nodes
end

-- Is `line` within any node's [start_line, end_line], allowing +/-1 for
-- how different node kinds account for their opening delimiter line.
local function covered(nodes, line)
    for _, n in ipairs(nodes) do
        local s, e = cmark.node_get_start_line(n), cmark.node_get_end_line(n)
        if line >= s - 1 and line <= e + 1 then return true end
    end
    return false
end

local function fence_covers(codeblocks, line, expected_info)
    for _, n in ipairs(codeblocks) do
        local s = cmark.node_get_start_line(n)
        if s >= line - 1 and s <= line + 1 then
            local info = (cmark.node_get_fence_info(n) or ""):gsub("%s+$", "")
            if info == expected_info then return true end
        end
    end
    return false
end

-- Run the four oracle assertions against a document body (a string, plus
-- its own line array for locating the constructs to check). Returns ok,
-- and a list of human-readable failure reasons (empty when ok).
local function check_oracle(body_text, body_lines)
    local reasons = {}
    local doc = cmark.parse_string(body_text, cmark.OPT_DEFAULT)
    if not doc then
        return false, { "cmark failed to parse the document body" }
    end

    local blockquotes = collect(doc, cmark.NODE_BLOCK_QUOTE)
    local lists       = collect(doc, cmark.NODE_LIST)
    local codeblocks  = collect(doc, cmark.NODE_CODE_BLOCK)

    -- Walk with tmscan so fence interiors and the opening-vs-closing
    -- marker line are distinguished the same way the runtime distinguishes
    -- them, rather than re-deriving that by regex here.
    local prev_fence_open = false
    for i, kind, fields, _, _, fence_open in tmscan.iter(body_lines) do
        if kind == "payload" then
            local content = fields.content
            if content:match("^> ") then
                if not covered(blockquotes, i) then
                    reasons[#reasons + 1] = string.format(
                        "line %d: labeled field did not produce a block_quote node", i)
                end
            elseif content:match("^%s*[%-%*%+] ") then
                if not covered(lists, i) then
                    reasons[#reasons + 1] = string.format(
                        "line %d: payload bullet did not produce a list node", i)
                end
            elseif fence_open and not prev_fence_open then
                -- The opening fence marker line.
                local info = (content:match("^`+(.*)$") or content:match("^~+(.*)$") or ""):gsub("%s+$", "")
                if not fence_covers(codeblocks, i, info) then
                    reasons[#reasons + 1] = string.format(
                        "line %d: payload fence did not produce a code_block node carrying info %q", i, info)
                end
            end
        end
        prev_fence_open = fence_open
    end

    -- The fell-out-of-its-list-item signature is specifically a swallowed
    -- blockquote marker that lazily continues the *previous line* of its
    -- paragraph, so it renders as "&gt;" at the very start of a line inside
    -- <p>/<li> text. An ordinary "->" arrow or comparison inside running
    -- prose (or an escaped `<TAG>`-shaped code span, e.g. `` `<YYYY>` ``,
    -- describing a path pattern) can legitimately contain "&gt;" elsewhere,
    -- so only a line-initial occurrence counts.
    local html = cmark.render_html(doc, cmark.OPT_DEFAULT)
    local prose_html = html:gsub("<code[^>]*>.-</code>", "")
    if prose_html:find("^&gt;") or prose_html:find("\n&gt;", 1, true) then
        reasons[#reasons + 1] = "rendered HTML has a line starting with &gt; (a payload fell out of its list item)"
    end

    cmark.node_free(doc)
    return #reasons == 0, reasons
end

-- Split a whole file's lines into a body (stripping frontmatter when it is
-- present and in the flat `---` form; falling back to the raw lines when
-- it is not -- tm init's templates predate that conversion and still use
-- fenced JSON frontmatter, which carries no payload constructs to check).
local function body_of(lines)
    local tbl, body_start = tmmeta.split_frontmatter(lines)
    if tbl then
        local body = {}
        for i = body_start, #lines do body[#body + 1] = lines[i] end
        return body
    end
    return lines
end

-- ── Every pass-* fixture ─────────────────────────────────────────────────

local fixtures_dir = script_dir .. "/fixtures"
local pipe = io.popen("ls " .. fixtures_dir .. " 2>/dev/null")
local fixtures = {}
if pipe then
    for name in pipe:lines() do
        if name:match("^pass%-.*%.md$") then fixtures[#fixtures + 1] = name end
    end
    pipe:close()
end
table.sort(fixtures)

for _, name in ipairs(fixtures) do
    local f = io.open(fixtures_dir .. "/" .. name, "r")
    local content = f:read("*a")
    f:close()

    local lines = tmscan.lines_of(content)
    local body_lines = body_of(lines)
    local ok, reasons = check_oracle(table.concat(body_lines, "\n"), body_lines)
    check("fixtures", name, ok, reasons[1])
end

-- ── Every file `tm init` writes ──────────────────────────────────────────

do
    local tmpdir = os.tmpname()
    os.remove(tmpdir)
    os.execute("mkdir -p " .. tmpdir)
    local cmd = string.format(
        "lua %s/../src/tminit.lua --tasks-dir %s >/dev/null 2>&1", script_dir, tmpdir)
    os.execute(cmd)

    local wrote_any = false
    local listing = io.popen("find " .. tmpdir .. " -type f 2>/dev/null")
    if listing then
        for path in listing:lines() do
            wrote_any = true
            local f = io.open(path, "r")
            local content = f and f:read("*a") or ""
            if f then f:close() end
            local lines = tmscan.lines_of(content)
            local body_lines = body_of(lines)
            local ok, reasons = check_oracle(table.concat(body_lines, "\n"), body_lines)
            check("tm init output", path:match("[^/]+$") or path, ok, reasons[1])
        end
        listing:close()
    end
    check("tm init output", "wrote at least one file", wrote_any)

    os.execute("rm -rf " .. tmpdir)
end

-- ── This repository's own doc/tasks/ files ────────────────────────────────

for _, name in ipairs({ "active.tm.md", "future.tm.md", "completed.tm.md" }) do
    local path = script_dir .. "/../doc/tasks/" .. name
    local f = io.open(path, "r")
    if f then
        local content = f:read("*a")
        f:close()
        local lines = tmscan.lines_of(content)
        local body_lines = body_of(lines)
        local ok, reasons = check_oracle(table.concat(body_lines, "\n"), body_lines)
        check("doc/tasks", name, ok, reasons[1])
    else
        check("doc/tasks", name, false, "file not found: " .. path)
    end
end

-- ── Every file `tm sweep`/`tm archive` write ──────────────────────────────
-- DoD 3 calls for "every file the tool writes"; sweep/rotate/archive are
-- exactly where rewriting a document could break its CommonMark reading,
-- so they get their own tmpdir round-trip rather than relying on the
-- static fixtures above.

do
    local tmpdir = os.tmpname()
    os.remove(tmpdir)
    local tasks_dir = tmpdir .. "/doc/tasks"
    os.execute("mkdir -p " .. tasks_dir)
    os.execute(string.format(
        "lua %s/../src/tminit.lua --tasks-dir %s >/dev/null 2>&1", script_dir, tasks_dir))

    local function append(path, text)
        local f = io.open(path, "a")
        f:write(text)
        f:close()
    end

    append(tasks_dir .. "/active.tm.md", [[

- [x] A swept task exercising every payload construct
    > **Completed:** 2000-01-01

    - a payload bullet

    ```sh
    echo hi
    ```
]])

    os.execute(string.format(
        "lua %s/../src/tmsweep.lua --sweep --tasks-dir %s >/dev/null 2>&1", script_dir, tasks_dir))

    -- Pad completed.tm.md past keep_min (10) with old, dated sections so
    -- the swept-in one actually ages out and `tm archive` has something to
    -- move -- keep_min alone protects any file with 10 or fewer sections
    -- regardless of date.
    local completed_path = tasks_dir .. "/completed.tm.md"
    local cf = io.open(completed_path, "r")
    local completed_content = cf:read("*a")
    cf:close()
    completed_content = completed_content:gsub("Completed:%*%* %d%d%d%d%-%d%d%-%d%d", "Completed:** 2000-01-01")
    local pad = {}
    for i = 1, 10 do
        pad[#pad + 1] = string.format(
            "\n## Sprint pad-%d\n- [x] padding task %d\n    > **Completed:** 2000-01-0%d\n", i, i, (i % 9) + 1)
    end
    local cwf = io.open(completed_path, "w")
    cwf:write(completed_content .. table.concat(pad))
    cwf:close()

    os.execute(string.format(
        "lua %s/../src/tmsweep.lua --archive --tasks-dir %s >/dev/null 2>&1", script_dir, tasks_dir))

    local checked_any = false
    local listing = io.popen("find " .. tasks_dir .. " -type f -name '*.md' 2>/dev/null")
    if listing then
        for path in listing:lines() do
            checked_any = true
            local f = io.open(path, "r")
            local content = f and f:read("*a") or ""
            if f then f:close() end
            local lines = tmscan.lines_of(content)
            local body_lines = body_of(lines)
            local ok, reasons = check_oracle(table.concat(body_lines, "\n"), body_lines)
            check("tm sweep/archive output", path:sub(#tasks_dir + 2), ok, reasons[1])
        end
        listing:close()
    end
    check("tm sweep/archive output", "checked at least one file", checked_any)

    os.execute("rm -rf " .. tmpdir)
end

-- ── Regression guard: six-space indent must break every assertion ────────
-- A synthetic task exercising all three payload constructs at once, at the
-- correct four-space indent (must pass) and again re-indented to six
-- spaces (must fail all three shape assertions plus the &gt; check).

local function synthetic(indent)
    local pad = string.rep(" ", indent)
    return {
        "# Tasks",
        "",
        "- [ ] A task exercising every payload construct",
        pad .. "> **Context:** a labeled field",
        "",
        pad .. "- a payload bullet",
        "",
        pad .. "```sh",
        pad .. "echo hi",
        pad .. "```",
    }
end

do
    local four = synthetic(4)
    local ok, reasons = check_oracle(table.concat(four, "\n"), four)
    check("regression guard", "four-space indent passes all four assertions", ok, reasons[1])
end

do
    local six = synthetic(6)
    local ok = check_oracle(table.concat(six, "\n"), six)
    check("regression guard", "six-space indent fails (this is the regression the suite exists to catch)", not ok)
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
