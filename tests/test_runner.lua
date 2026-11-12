#!/usr/bin/env lua
-- test_runner.lua — Run tmval.lua against every fixture in tests/fixtures/
-- Files named pass-* are expected to exit 0; fail-* are expected to exit 1.

local tmval_path = arg[1] or "./tmval.lua"
local fixtures_dir = arg[2] or "./tests/fixtures"

local passed = 0
local failed = 0
local results = {}

-- SPEC-TASKMARK-05 §1.5 rule each fail-* fixture is expected to trip. tmval
-- reports each violation as "Line N: V<n>: <message>", so matching the rule
-- code is sufficient and doesn't couple this table to exact wording.
local expected_diagnostics = {
    ["fail-bad-label.tm.md"] = "V10:",
    ["fail-bad-task-token.tm.md"] = "V6:",
    ["fail-label-no-blank.tm.md"] = "V11:",
    ["fail-mixed-indent.tm.md"] = "V7:",
    ["fail-nested-task.tm.md"] = "V9:",
    ["fail-nested-task-indent.tm.md"] = "V7:",
    ["fail-setext-header.tm.md"] = "V4:",
    ["fail-tab-indent.tm.md"] = "V3:",
    ["fail-toplevel-blockquote.tm.md"] = "V5:",
    ["fail-toplevel-fence.tm.md"] = "V5:",
    ["fail-toplevel-html.tm.md"] = "V5:",
    ["fail-toplevel-thematic-break.tm.md"] = "V5:",
    ["fail-unclosed-payload-fence.tm.md"] = "V12:",
    ["fail-v13-lazy-continuation.tm.md"] = "V13:",
    ["fail-v13-prose-after-task.tm.md"] = "V13:",
    ["fail-v14-frontmatter.tm.md"] = "V14:",
    ["fail-wrong-indent.tm.md"] = "V7:",
}

-- Check tmval exists
local f = io.open(tmval_path, "r")
if not f then
    io.stderr:write("Error: " .. tmval_path .. " not found.\n")
    os.exit(1)
end
f:close()

-- Collect fixture files
local pipe = io.popen("ls " .. fixtures_dir .. " 2>/dev/null")
if not pipe then
    io.stderr:write("Error: cannot list " .. fixtures_dir .. "\n")
    os.exit(1)
end

local fixtures = {}
for file in pipe:lines() do
    if file:match("%.md$") then
        table.insert(fixtures, file)
    end
end
pipe:close()

if #fixtures == 0 then
    io.stderr:write("Error: no .md fixtures found in " .. fixtures_dir .. "\n")
    os.exit(1)
end

-- Sort for deterministic order
table.sort(fixtures)

print("Running " .. #fixtures .. " test(s)...\n")

for _, fixture in ipairs(fixtures) do
    local fixture_path = fixtures_dir .. "/" .. fixture
    local expected_exit
    local category

    if fixture:match("^pass%-") then
        expected_exit = 0
        category = "PASS"
    elseif fixture:match("^fail%-") then
        expected_exit = 1
        category = "FAIL"
    else
        print("  [SKIP] " .. fixture .. " (does not start with pass- or fail-)")
        table.insert(results, {fixture = fixture, status = "SKIP"})
        goto continue
    end

    -- Capture exit code reliably via shell echo
    local cmd = string.format("lua %s %s 2>&1; echo __EXIT__$?", tmval_path, fixture_path)
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()

    -- Parse __EXIT__<code> from last line of output
    local exit_code = 0
    local last_line
    for line in output:gmatch("[^\n]+") do
        last_line = line
    end
    if last_line then
        local marker = last_line:match("__EXIT__(%d+)")
        if marker then
            exit_code = tonumber(marker)
            -- Strip the marker line from output
            output = output:gsub("__EXIT__%d+\n?", "")
        end
    end

    local status
    local fail_reason
    if exit_code == expected_exit then
        status = "PASS"
        if expected_diagnostics[fixture] then
            local expected_text = expected_diagnostics[fixture]
            if not output:find(expected_text, 1, true) then
                status = "FAIL"
                fail_reason = "missing expected diagnostic text: " .. expected_text
            end
        end
    else
        status = "FAIL"
        fail_reason = string.format("expected exit %d, got %d", expected_exit, exit_code)
    end

    if status == "PASS" then
        passed = passed + 1
    else
        failed = failed + 1
    end

    local symbol
    if status == "PASS" then
        symbol = "\27[32m[PASS]\27[0m"
    else
        symbol = "\27[31m[FAIL]\27[0m"
    end

    print(string.format("  %s %s (expected=%d, got=%d)", symbol, fixture, expected_exit, exit_code))
    if status == "FAIL" then
        -- Show first few lines of output for debugging
        local lines = {}
        for line in output:gmatch("[^\n]+") do
            table.insert(lines, line)
        end
        for i = 1, math.min(#lines, 4) do
            print("       " .. lines[i])
        end
        print("")
    end

    table.insert(results, {fixture = fixture, category = category, status = status,
                           expected = expected_exit, got = exit_code,
                           fail_reason = fail_reason})

    ::continue::
end

-- ── Multi-file and CLI tests ──────────────────────────────────────────────

local function run_val(args)
    local cmd = string.format("lua %s %s 2>&1; echo __EXIT__$?", tmval_path, args)
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()
    local exit_code = 0
    local last_line
    for line in output:gmatch("[^\n]+") do
        last_line = line
    end
    if last_line then
        local marker = last_line:match("__EXIT__(%d+)")
        if marker then
            exit_code = tonumber(marker)
            output = output:gsub("__EXIT__%d+\n?", "")
        end
    end
    output = output:gsub("\27%[[%d;]*m", "")
    return output, exit_code
end

local function test_cli(name, ok, reason)
    local symbol
    if ok then
        passed = passed + 1
        symbol = "\27[32m[PASS]\27[0m"
        print(string.format("  %s %s", symbol, name))
        table.insert(results, {fixture = name, status = "PASS"})
    else
        failed = failed + 1
        symbol = "\27[31m[FAIL]\27[0m"
        print(string.format("  %s %s (%s)", symbol, name, reason or "failed"))
        table.insert(results, {fixture = name, status = "FAIL", fail_reason = reason, expected = 0, got = 1})
    end
end

print("\nRunning multi-file and CLI test(s)...\n")

do
    local out, code = run_val(string.format("%s/pass-blank-lines.tm.md %s/pass-valid-basic.tm.md", fixtures_dir, fixtures_dir))
    test_cli("multi-file: multiple valid files exit 0", code == 0, "expected exit 0, got " .. code)
    test_cli("multi-file: multiple valid files all reported PASS",
        out:find("pass-blank-lines.tm.md conforms to SPEC-TASKMARK-05", 1, true) ~= nil and
        out:find("pass-valid-basic.tm.md conforms to SPEC-TASKMARK-05", 1, true) ~= nil)
end

do
    local out, code = run_val(string.format("%s/pass-valid-basic.tm.md %s/fail-bad-label.tm.md", fixtures_dir, fixtures_dir))
    test_cli("multi-file: pass and fail exits 1", code == 1, "expected exit 1, got " .. code)
    test_cli("multi-file: passing file reported", out:find("pass-valid-basic.tm.md conforms", 1, true) ~= nil)
    test_cli("multi-file: failing file reported with filename prefix",
        out:find("fail-bad-label.tm.md: Line", 1, true) ~= nil and out:find("V10:", 1, true) ~= nil)
    test_cli("multi-file: summary reports total errors", out:find("Validation failed with 1 error(s).", 1, true) ~= nil)
end

do
    local out, code = run_val(string.format("%s/fail-bad-label.tm.md %s/fail-bad-task-token.tm.md", fixtures_dir, fixtures_dir))
    test_cli("multi-file: two failing files exit 1", code == 1, "expected exit 1, got " .. code)
    test_cli("multi-file: both failing files reported with filename prefix",
        out:find("fail-bad-label.tm.md: Line", 1, true) ~= nil and out:find("fail-bad-task-token.tm.md: Line", 1, true) ~= nil)
    test_cli("multi-file: failure count is accumulated", out:find("Validation failed with 2 error(s).", 1, true) ~= nil)
end

do
    local out, code = run_val(string.format("nonexistent.tm.md %s/pass-valid-basic.tm.md", fixtures_dir))
    test_cli("multi-file: missing file exits 1", code == 1, "expected exit 1, got " .. code)
    test_cli("multi-file: missing file reported", out:find("Target task file 'nonexistent.tm.md' not found", 1, true) ~= nil)
    test_cli("multi-file: valid file still validated when another file is missing",
        out:find("pass-valid-basic.tm.md conforms", 1, true) ~= nil)
end

do
    local out, code = run_val(string.format("%s/fail-bad-label.tm.md", fixtures_dir))
    test_cli("single-file: failure line format preserved", out:find("%[FAIL%] Line %d+: V10:") ~= nil)
end

do
    local out_h, code_h = run_val("-h")
    test_cli("cli: -h exits 0", code_h == 0)
    test_cli("cli: -h output contains usage", out_h:find("Usage:", 1, true) ~= nil and out_h:find("tm validate", 1, true) ~= nil)
    local out_help, code_help = run_val("--help")
    test_cli("cli: --help exits 0", code_help == 0)
end

do
    local tm_path = tmval_path:gsub("tmval%.lua$", "tm")
    local cmd = string.format("lua %s validate %s/pass-blank-lines.tm.md %s/pass-valid-basic.tm.md 2>&1; echo __EXIT__$?", tm_path, fixtures_dir, fixtures_dir)
    local handle = io.popen(cmd)
    local out_tm = handle:read("*a")
    handle:close()
    local code_tm = tonumber(out_tm:match("__EXIT__(%d+)")) or -1
    out_tm = out_tm:gsub("\27%[[%d;]*m", "")
    test_cli("tm dispatcher: validates multiple files",
        code_tm == 0 and out_tm:find("pass-blank-lines", 1, true) ~= nil and out_tm:find("pass-valid-basic", 1, true) ~= nil)
end

-- Tests for tm validate --fix
do
    local tmp_fix = "/tmp/tm_cli_fix_test.tm.md"

    -- 1. --fix on already passing file
    local out_pass, code_pass = run_val(string.format("--fix %s/pass-valid-basic.tm.md", fixtures_dir))
    test_cli("--fix: passing file exits 0", code_pass == 0)
    test_cli("--fix: passing file reports conforms", out_pass:find("conforms to SPEC-TASKMARK-05", 1, true) ~= nil)

    -- 2. --fix on fixable file with V8, V10, V11, and V6
    local bad_content = [[# Preamble

- Top-level bullet item

## Phase 1

- [ ] (A) Task with errors
    > **Created:** 2026-10-01
    > **Progress:** first line
    > second wrapped line
    Freeform content without blank line
    - First bullet
      hanging continuation line
]]
    local f = io.open(tmp_fix, "w")
    f:write(bad_content)
    f:close()

    local out_pre, code_pre = run_val(tmp_fix)
    test_cli("--fix: fixture fails without --fix", code_pre == 1)

    local out_fixed, code_fixed = run_val("--fix " .. tmp_fix)
    test_cli("--fix: repair exits 0", code_fixed == 0)
    test_cli("--fix: reports [FIXED]", out_fixed:find("%[FIXED%]") ~= nil)

    -- Verify that the repaired file now passes ordinary tm validate
    local out_post, code_post = run_val(tmp_fix)
    test_cli("--fix: repaired file passes validation without --fix", code_post == 0)

    local fixed_file_content = io.open(tmp_fix, "r"):read("*a")
    test_cli("--fix: loose '-' converted to '*'", fixed_file_content:find("%* Top%-level bullet item") ~= nil)
    test_cli("--fix: does not use unicode bullet", fixed_file_content:find("•") == nil)

    -- 3. --fix on unfixable file exits 1
    local out_unfix, code_unfix = run_val(string.format("--fix %s/fail-unclosed-payload-fence.tm.md", fixtures_dir))
    test_cli("--fix: unfixable file exits 1", code_unfix == 1)
    test_cli("--fix: unfixable file reports [FAIL]", out_unfix:find("%[FAIL%]") ~= nil)

    os.remove(tmp_fix)

    -- 4. --fix writes through the shared atomic writer: the document's CRLF
    -- newline style survives, and no temporary file is left beside it.
    local crlf_dir = os.tmpname()
    os.remove(crlf_dir)
    os.execute("mkdir -p '" .. crlf_dir .. "'")
    local crlf_path = crlf_dir .. "/crlf.tm.md"
    local fc = io.open(crlf_path, "wb")
    fc:write((bad_content:gsub("\n", "\r\n")))
    fc:close()

    local _, code_crlf = run_val("--fix " .. crlf_path)
    test_cli("--fix: CRLF document repaired", code_crlf == 0)
    local fr = io.open(crlf_path, "rb")
    local crlf_body = fr:read("*a")
    fr:close()
    test_cli("--fix: CRLF newline style preserved",
        crlf_body:find("\r\n", 1, true) ~= nil and crlf_body:gsub("\r\n", ""):find("\n", 1, true) == nil)
    local ls = io.popen("ls -A '" .. crlf_dir .. "'")
    local listing = ls:read("*a")
    ls:close()
    test_cli("--fix: leaves no temporary file behind", listing == "crlf.tm.md\n", "found: " .. listing)
    os.execute("rm -rf '" .. crlf_dir .. "'")
end

-- V13 / V14 diagnostics and --fix repairs
do
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p '" .. dir .. "'")
    local function write(name, body)
        local f = io.open(dir .. "/" .. name, "w")
        f:write(body)
        f:close()
        return dir .. "/" .. name
    end
    local function read(path)
        local f = io.open(path, "r")
        local b = f:read("*a")
        f:close()
        return b
    end

    -- A pre-0.4 frontmatter block is reported once, as V14, without the
    -- misleading V4/V5 errors its `---` and `key: value` lines would raise.
    local out = run_val(fixtures_dir .. "/fail-v14-frontmatter.tm.md")
    test_cli("V14: frontmatter reported as V14", out:find("V14:", 1, true) ~= nil, out)
    test_cli("V14: no spurious V4/V5 for the frontmatter lines",
        out:find("V4:", 1, true) == nil and out:find("V5:", 1, true) == nil, out)

    local fm = write("fm.tm.md", "---\ntaskmark: 0.3\nrole: active\n---\n\n# Current Sprint\n\n- [ ] Kept\n")
    local _, code = run_val("--fix " .. fm)
    test_cli("V14: --fix strips the frontmatter block", code == 0 and read(fm) == "# Current Sprint\n\n- [ ] Kept\n", read(fm))

    local v13 = write("v13.tm.md", "# A\n\n- [ ] One\n    > **Note:** x\nAfter payload\n\n- [ ] Two\nAfter task\n")
    _, code = run_val("--fix " .. v13)
    test_cli("V13: --fix separates prose from a payload and from a task line",
        code == 0 and read(v13) == "# A\n\n- [ ] One\n    > **Note:** x\n\nAfter payload\n\n- [ ] Two\n\nAfter task\n", read(v13))

    os.execute("rm -rf '" .. dir .. "'")
end

-- Tests for top-level prose lists (*, +, 1.) and unicode bullet conversion
do
    local tmp_prose = "/tmp/tm_cli_prose_test.tm.md"
    local valid_prose_lists = [[# Preamble

* Asterisk bullet
+ Plus bullet
1. Numbered item
2) Numbered paren item

- [ ] (A) Valid task
]]
    local f_prose = io.open(tmp_prose, "w")
    f_prose:write(valid_prose_lists)
    f_prose:close()
    local out_p, code_p = run_val(tmp_prose)
    test_cli("top-level lists: *, +, and 1. are allowed as prose", code_p == 0)
    os.remove(tmp_prose)

    local tmp_uni = "/tmp/tm_cli_uni_test.tm.md"
    local unicode_bullet_content = [[# Preamble

- Loose bullet
• Old unicode bullet

- [ ] (A) Task
]]
    local f_uni = io.open(tmp_uni, "w")
    f_uni:write(unicode_bullet_content)
    f_uni:close()
    local out_u, code_u = run_val("--fix " .. tmp_uni)
    test_cli("--fix: repair with unicode bullet exits 0", code_u == 0)
    local fixed_uni = io.open(tmp_uni, "r"):read("*a")
    test_cli("--fix: converts unicode bullet '•' to '*'", fixed_uni:find("%* Old unicode bullet") ~= nil)
    os.remove(tmp_uni)
end

-- SPEC-TASKMARK-05 Tests: Multi-line labeled fields (V10) and Payload sub-lists / continuation indents (V8)
do
    local tmp_spec03 = "/tmp/tm_cli_spec03_test.tm.md"

    -- 1. Valid multi-line labeled field passes validation
    local valid_multiline_label = [[# Tasks

- [ ] (A) Task with multi-line labeled field
    > **Context:** First line of context.
    > Second continuation line.
    > Third continuation line.

    Freeform payload prose follows blank line.
]]
    local f1 = io.open(tmp_spec03, "w")
    f1:write(valid_multiline_label)
    f1:close()
    local out1, code1 = run_val(tmp_spec03)
    test_cli("SPEC-TASKMARK-05: multi-line labeled field passes validation", code1 == 0)

    -- 2. Valid payload sub-list and hanging continuation line passes validation
    local valid_payload_sublist = [[# Tasks

- [ ] (A) Task with sub-lists
    > **Context:** Single line context.

    - First top-level payload bullet
      hanging continuation line under bullet
      - Nested sub-bullet at 2 spaces
        hanging continuation under nested bullet
      * Nested asterisk bullet
      + Nested plus bullet
]]
    local f2 = io.open(tmp_spec03, "w")
    f2:write(valid_payload_sublist)
    f2:close()
    local out2, code2 = run_val(tmp_spec03)
    test_cli("SPEC-TASKMARK-05: payload sub-lists and continuation indents pass validation", code2 == 0)

    -- 3. Forbidden: 6+ spaces after a blank line outside code fence still fails Rule V8
    local bad_blank_indent = [[# Tasks

- [ ] (A) Task with bad indent
    > **Context:** Some context.

      Indented 6 spaces after a blank line
]]
    local f3 = io.open(tmp_spec03, "w")
    f3:write(bad_blank_indent)
    f3:close()
    local out3, code3 = run_val(tmp_spec03)
    test_cli("SPEC-TASKMARK-05: 6+ spaces after blank line fails Rule V8", code3 == 1 and out3:find("V8:", 1, true) ~= nil)

    -- 4. Forbidden: excessive indentation past column 8 (content indent > 4) still fails Rule V8
    local bad_excess_indent = [[# Tasks

- [ ] (A) Task with excess indent
    - Bullet item
          Over-indented 6 spaces content (column 11)
]]
    local f4 = io.open(tmp_spec03, "w")
    f4:write(bad_excess_indent)
    f4:close()
    local out4, code4 = run_val(tmp_spec03)
    test_cli("SPEC-TASKMARK-05: >4 spaces content indent fails Rule V8", code4 == 1 and out4:find("V8:", 1, true) ~= nil)

    -- 5. --fix preserves multi-line labeled fields and sub-lists
    local fix_preserves = [[# Tasks

- Top-level loose bullet

- [ ] (A) Task with multiline and sublist
    > **Context:** First line.
    > Second continuation line.

    - First bullet
      - Nested bullet
]]
    local f5 = io.open(tmp_spec03, "w")
    f5:write(fix_preserves)
    f5:close()
    local out5, code5 = run_val("--fix " .. tmp_spec03)
    test_cli("SPEC-TASKMARK-05: --fix succeeds on fixture", code5 == 0)
    local fixed_content = io.open(tmp_spec03, "r"):read("*a")
    test_cli("SPEC-TASKMARK-05: --fix preserves multi-line labeled field", fixed_content:find("    > Second continuation line%.") ~= nil)
    test_cli("SPEC-TASKMARK-05: --fix preserves sub-bullet indent", fixed_content:find("      %- Nested bullet") ~= nil)

    os.remove(tmp_spec03)
end

-- Summary
print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))

if failed > 0 then
    print("Failed tests:")
    for _, r in ipairs(results) do
        if r.status == "FAIL" then
            if r.fail_reason then
                print("  " .. r.fixture .. " (" .. r.fail_reason .. ")")
            else
                print("  " .. r.fixture .. " (expected exit " .. r.expected .. ", got " .. r.got .. ")")
            end
        end
    end
    print("")
    os.exit(1)
else
    os.exit(0)
end
