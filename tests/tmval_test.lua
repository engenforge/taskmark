#!/usr/bin/env lua
-- tests/tmval_test.lua — tm validate behavior beyond the pass/fail fixture
-- corpus (tests/test_runner.lua): non-fatal warnings (§1.5), the V7
-- message for an indented line outside a task, and colour output.

local script_dir = (arg[0] or "./tests/tmval_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmscan = require("tmscan")
local tmval  = require("tmval")
local tmio   = require("tmio")

local passed, failed = 0, 0

local function check(group, name, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s: %s", group, name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s: %s%s", group, name, detail and (" -- " .. tostring(detail)) or ""))
    end
end

local function warnings_of(text)
    return tmval.validate_warnings(tmscan.lines_of(text))
end

local function has(warnings, line, fragment)
    for _, w in ipairs(warnings) do
        if w.line == line and w.msg:find(fragment, 1, true) then return true end
    end
    return false
end

-- ── Warnings: registered date fields ──────────────────────────────────────

do
    local w = warnings_of([[
- [x] Task
    > **Created:** 2026-11-07
    > **Due:** 2026-12-01
    > **Completed:** 2026-11-08 git:a1b2c3d
]])
    check("warn", "well-formed dates raise nothing", #w == 0, w[1] and w[1].msg)

    w = warnings_of("- [x] Task\n    > **Completed:** 2026-11-08\n")
    check("warn", "Completed without a hash is well formed", #w == 0)

    w = warnings_of([[
- [ ] Task
    > **Created:** 2026-11-07 by an agent
    > **Due:** tomorrow
    > **Completed:** 2026-13-45
]])
    check("warn", "Created with trailing text", has(w, 2, "Created") and has(w, 2, "YYYY-MM-DD"))
    check("warn", "Due that is not a date", has(w, 3, "Due"))
    check("warn", "Completed with an impossible date", has(w, 4, "Completed"))

    w = warnings_of("- [x] Task\n    > **Completed:** 2026-11-08 git:xyz\n")
    check("warn", "Completed with a malformed hash", has(w, 2, "git:<sha>"))
    w = warnings_of("- [x] Task\n    > **Completed:** 2026-11-08 (see notes)\n")
    check("warn", "Completed with trailing text", has(w, 2, "Completed"))
end

-- ── Warnings: a second field written on the same line ─────────────────────

do
    local w = warnings_of("- [ ] Task\n    > **Notes:** see the parser. **Branch:** `testinfra`. **Depends:** id:k7q2x.\n")
    check("warn", "a **Key:** inside a value is reported once per line",
        #w == 1 and has(w, 2, "**Branch:**") and has(w, 2, "one field per line"), w[1] and w[1].msg)

    w = warnings_of("- [ ] Task\n    > **Notes:** first line\n    > and **Owner:** someone\n")
    check("warn", "also on a continuation line", #w == 1 and has(w, 3, "**Owner:**"))

    w = warnings_of("- [ ] Task\n    > **Notes:** plain **bold** text and a time 10:30\n")
    check("warn", "ordinary bold text is not a field", #w == 0)

    w = warnings_of("- [ ] Task\n    > **Notes:** stamp a `> **Completed:**` line beneath the task\n")
    check("warn", "a **Key:** quoted in a code span is not a field", #w == 0, w[1] and w[1].msg)

    w = warnings_of("- [ ] Task\n\n    ```\n    > **Due:** tomorrow **Key:** x\n    ```\n")
    check("warn", "fenced content is never inspected", #w == 0)

    w = warnings_of("- [ ] Task\n\n    Prose with **Key:** in it and a Due: tomorrow\n")
    check("warn", "freeform payload content is never inspected", #w == 0)
end

-- ── Warnings: completed tasks are a record ────────────────────────────────

do
    local w = warnings_of([[
- [x] Old task
    > **Created:** 2026-11-07 by someone. **Branch:** `main`.
    > **Completed:** 2026-11-08 git:a1b2c3d

- [ ] Open task
    > **Created:** 2026-11-07 by someone
]])
    check("warn", "a completed task's other fields are not reported",
        #w == 1 and has(w, 6, "Created"), w[1] and (w[1].line .. " " .. w[1].msg))

    w = warnings_of("- [x] Old task\n    > **Completed:** last week\n")
    check("warn", "its Completed stamp still is", #w == 1 and has(w, 2, "Completed"))
end

-- ── V7: an indented line outside a task ───────────────────────────────────

do
    local errs = tmval.validate_lines(tmscan.lines_of("# S\n\n1. first item\n   continued here\n"))
    check("V7", "indented line outside a task names the likely cause",
        #errs == 1 and errs[1].rule == "V7" and errs[1].msg:find("outside a task", 1, true) ~= nil
        and errs[1].msg:find("column 0", 1, true) ~= nil, errs[1] and errs[1].msg)

    errs = tmval.validate_lines(tmscan.lines_of("- [ ] Task\n  two spaces\n"))
    check("V7", "under a task it is still a payload indent error",
        (function()
            for _, e in ipairs(errs) do
                if e.rule == "V7" then return e.msg:find("payload line", 1, true) ~= nil end
            end
            return false
        end)())

    errs = tmval.validate_lines(tmscan.lines_of("# S\n\n - [ ] One space\n"))
    check("V7", "an indented task line outside a task is named as one, with both remedies",
        #errs == 1 and errs[1].rule == "V7" and errs[1].msg:find("task line indented 1 space:", 1, true) ~= nil
        and errs[1].msg:find("column 0", 1, true) ~= nil and errs[1].msg:find("payload", 1, true) ~= nil,
        errs[1] and errs[1].msg)

    errs = tmval.validate_lines(tmscan.lines_of("- [ ] Task\n\n   - [x] Three spaces\n"))
    check("V7", "so is one beneath a task",
        #errs == 1 and errs[1].rule == "V7" and errs[1].msg:find("task line indented 3 spaces:", 1, true) ~= nil,
        errs[1] and errs[1].msg)

    errs = tmval.validate_lines(tmscan.lines_of("- [ ] Task\n    - [ ] Four spaces\n"))
    check("V7", "a four-space task token is a payload matter, not V7",
        (function()
            for _, e in ipairs(errs) do if e.rule == "V7" then return false end end
            return true
        end)())

    errs = tmval.validate_lines(tmscan.lines_of("# S\n\n1. first item\ncontinued at column 0\n"))
    check("V7", "a wrapped list line at column 0 conforms", #errs == 0)
end

-- ── Colour ────────────────────────────────────────────────────────────────

check("colour", "on for a terminal", tmio.color_enabled(true, nil) == true)
check("colour", "off when stdout is not a terminal", tmio.color_enabled(false, nil) == false)
check("colour", "off when NO_COLOR is set", tmio.color_enabled(true, "1") == false)
check("colour", "an empty NO_COLOR does not count", tmio.color_enabled(true, "") == true)

-- ── CLI ───────────────────────────────────────────────────────────────────

do
    local tm_abs = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")
    local dir = string.format("/tmp/tm_val_test_%d_%s", os.time(), tmio.unique_token())
    tmio.mkdir_p(dir)
    local function write(name, body)
        local f = assert(io.open(dir .. "/" .. name, "w"))
        f:write(body)
        f:close()
    end
    local function validate(args)
        local p = io.popen(string.format("cd %s && lua %s validate %s 2>&1; echo __EXIT__$?",
            tmio.shell_quote(dir), tm_abs, args))
        local out = p:read("*a")
        p:close()
        local code = tonumber(out:match("__EXIT__(%d+)")) or -1
        return out:gsub("__EXIT__%d+%s*$", ""), code
    end

    write("clean.tm.md", "# S\n\n- [ ] Task id:aaaaa\n")
    write("bad.tm.md", "# S\n\n- [ ] Task\n  two spaces\n")
    write("warn.tm.md", "# S\n\n- [ ] Task id:aaaaa\n    > **Due:** tomorrow\n")

    local out, code = validate("clean.tm.md")
    check("cli", "no escape sequences when stdout is a pipe",
        code == 0 and out == "[PASS] clean.tm.md conforms to SPEC-TASKMARK-06.\n", out)
    out, code = validate("bad.tm.md")
    check("cli", "failures are plain text too", code == 1 and not out:find("\27", 1, true) and out:find("[FAIL] Line 4: V7:", 1, true) ~= nil, out)

    out, code = validate("warn.tm.md")
    check("cli", "a warning is printed and the file still passes",
        code == 0 and out:find("[WARN] Line 4: ", 1, true) ~= nil and out:find("[PASS] warn.tm.md", 1, true) ~= nil, out)

    out, code = validate("clean.tm.md warn.tm.md")
    check("cli", "several files: warnings name their file",
        code == 0 and out:find("[WARN] warn.tm.md: Line 4: ", 1, true) ~= nil, out)
    check("cli", "an identifier on two tasks is a warning, not a failure",
        code == 0 and out:find("[WARN] id:aaaaa is carried by 2 tasks: clean.tm.md:3, warn.tm.md:3", 1, true) ~= nil, out)

    -- --fix never guesses whether an indented task line is a misplaced
    -- task or a sub-item: it leaves the file alone and says so.
    local indented_body = "# Sprint\n\n  - [ ] Indented task id:qspwd\n      > **Context:** two-space indent\n"
    write("indented.tm.md", indented_body)
    out, code = validate("--fix indented.tm.md")
    check("fix indented task", "an indented task block is not repaired",
        code == 1 and out:find("[FAIL] Line 3: V7: task line indented 2 spaces", 1, true) ~= nil
        and out:find("wrote nothing", 1, true) ~= nil, out)
    check("fix indented task", "the file stays byte-for-byte unchanged",
        assert(io.open(dir .. "/indented.tm.md", "r")):read("*a") == indented_body)

    local tight_sub = "# Sprint\n\n- [ ] Parent task\n  - [ ] Tight sub-item\n"
    write("tight_sub.tm.md", tight_sub)
    out, code = validate("--fix tight_sub.tm.md")
    check("fix indented task", "tight sub-item directly beneath a task becomes a payload bullet",
        code == 0 and out:find("[FIXED]", 1, true) ~= nil
        and assert(io.open(dir .. "/tight_sub.tm.md", "r")):read("*a") ==
            "# Sprint\n\n- [ ] Parent task\n    - Tight sub-item\n", out)

    local after_blank = "# Sprint\n\n- [ ] First task\n\n  - [ ] Second task\n      > **Notes:** indented\n"
    write("after_blank.tm.md", after_blank)
    out, code = validate("--fix after_blank.tm.md")
    check("fix indented task", "indented task after a blank line is left alone with V7",
        code == 1 and out:find("Line 5: V7: task line indented 2 spaces", 1, true) ~= nil
        and out:find("wrote nothing", 1, true) ~= nil
        and assert(io.open(dir .. "/after_blank.tm.md", "r")):read("*a") == after_blank, out)

    -- --fix: unrepairable file reports that nothing was written and leaves bytes untouched
    local unfixable_body = "# S\n\n- [ ] Task\n\n    ```lua\n    local x = 1\n"
    write("unfixable.tm.md", unfixable_body)
    out, code = validate("--fix unfixable.tm.md")
    check("fix unrepairable", "exits 1", code == 1, out)
    local fail_pos = out:find("[FAIL] Line ", 1, true)
    local wrote_pos = out:find("wrote nothing", 1, true)
    check("fix unrepairable", "prints [FAIL] lines then says --fix could not repair and wrote nothing",
        fail_pos ~= nil and wrote_pos ~= nil and fail_pos < wrote_pos
        and out:find("unfixable.tm.md", 1, true) ~= nil
        and out:find("--fix could not repair", 1, true) ~= nil, out)
    local after_unfix = assert(io.open(dir .. "/unfixable.tm.md", "r")):read("*a")
    check("fix unrepairable", "file stays byte-for-byte unchanged", after_unfix == unfixable_body)

    -- --fix: when nothing is written, line numbers match the file on disk
    local shifted_body = table.concat({
        "---",
        "title: Old",
        "---",
        "",
        "# S",
        "",
        "- [ ] Task",
        "",
        "    ```lua",
        "    local x = 1",
        "",
    }, "\n")
    write("shifted.tm.md", shifted_body)
    local plain_out = validate("shifted.tm.md")
    local fix_out, fix_code = validate("--fix shifted.tm.md")
    check("fix unrepairable", "line numbers match the untouched file on disk",
        fix_code == 1
        and plain_out:find("Line 9: V12:", 1, true) ~= nil
        and fix_out:find("Line 9: V12:", 1, true) ~= nil,
        "plain:\n" .. plain_out .. "\nfix:\n" .. fix_out)

    os.execute("rm -rf " .. tmio.shell_quote(dir))
end

-- ── Claimed field warnings (id:gs33j) ────────────────────────────────────

do
    local clean = table.concat({
        "# Sprint",
        "",
        "- [ ] Date alone",
        "    > **Claimed:** 2026-11-16",
        "",
        "- [ ] Date with claimant",
        "    > **Claimed:** 2026-11-16 stream/s1",
        "",
        "- [x] Completed task with bad and duplicate Claimed",
        "    > **Completed:** 2026-11-16",
        "    > **Claimed:** not-a-date",
        "    > **Claimed:** 2026-11-16 second",
        "",
        "- [ ] Fenced bad Claimed",
        "    ```markdown",
        "    > **Claimed:** not-a-date",
        "    > **Claimed:** 2026-11-16",
        "    ```",
        "",
    }, "\n")
    check("claimed warnings", "date alone, date+claimant, completed task, and fenced Claimed are clean",
        #warnings_of(clean) == 0, tostring(#warnings_of(clean)))

    for _, bad in ipairs({
        { "missing date", "    > **Claimed:** " },
        { "impossible date", "    > **Claimed:** 2026-02-30 stream/s1" },
        { "claimant with no date", "    > **Claimed:** stream/s1" },
    }) do
        local doc = "# Sprint\n\n- [ ] Task\n" .. bad[2] .. "\n"
        local ws = warnings_of(doc)
        check("claimed warnings", bad[1] .. " warns",
            #ws == 1 and ws[1].msg:find("Claimed:", 1, true) ~= nil, ws[1] and ws[1].msg or "none")
    end

    local dup = "# Sprint\n\n- [ ] Task\n    > **Claimed:** 2026-11-16 s1\n    > **Claimed:** 2026-11-16 s2\n"
    local dws = warnings_of(dup)
    check("claimed warnings", "two Claimed fields on one task warn",
        #dws == 1 and dws[1].line == 5 and dws[1].msg:find("Claimed", 1, true) ~= nil, dws[1] and dws[1].msg or "none")

    -- Exit status via CLI remains 0 when Claimed warns
    local dir = string.format("/tmp/tm_val_claimed_%d_%s", os.time(), tmio.unique_token())
    tmio.mkdir_p(dir)
    local bad_path = dir .. "/bad_claimed.tm.md"
    local f = assert(io.open(bad_path, "w"))
    f:write("# Sprint\n\n- [ ] Task\n    > **Claimed:** nope\n")
    f:close()
    local p = io.popen("lua src/tmval.lua " .. tmio.shell_quote(bad_path) .. " 2>&1; echo __CODE__$?")
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("__CODE__(%d+)%s*$"))
    check("claimed warnings", "CLI exits 0 when Claimed warns",
        code == 0 and out:find("[WARN]", 1, true) ~= nil and out:find("Claimed:", 1, true) ~= nil, out)
    os.execute("rm -rf " .. tmio.shell_quote(dir))
end

print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
