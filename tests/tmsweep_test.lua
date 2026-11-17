#!/usr/bin/env lua
-- tests/tmsweep_test.lua — unit + end-to-end tests for tmsweep_core.lua /
-- tmsweep.lua (SPEC-TASKMARK-06 §5.3-§5.5: task-level sweep, blank-line
-- normalization, and archive aging).
--
-- Self-contained runner (no shared harness with other repos — this project's
-- own tests/test_runner.lua is fixture-specific to tmval.lua's pass-/fail-
-- convention and doesn't fit assert-style unit tests).

local script_dir = (arg[0] or "./tests/tmsweep_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. script_dir .. "/../vendor/?.lua;" .. package.path

local core = require("tmsweep_core")
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

-- Split a Lua long-string literal into a 1-indexed lines array.
local function lines_of(s)
    local t = {}
    for l in (s .. "\n"):gmatch("(.-)\n") do table.insert(t, l) end
    if t[#t] == "" then table.remove(t) end
    return t
end

local function join(lines)
    return table.concat(lines, "\n")
end

-- ── sweep() ──────────────────────────────────────────────────────────────

do
    local active = lines_of([[
# Current Sprint

- [ ] Pending task

- [x] Done task one
    > **Completed:** 2026-09-01

- [x] Done task two
    > **Completed:** 2026-09-01]])
    local new_active, moved = core.sweep(active)
    check("sweep", "sweeps exactly the two completed tasks", moved ~= nil and #moved == 2)
    check("sweep", "heading remains in the replacement active lines",
          join(new_active):match("# Current Sprint") ~= nil)
    check("sweep", "pending task remains in place",
          join(new_active):match("Pending task") ~= nil)
    check("sweep", "completed tasks are gone from the replacement",
          not join(new_active):match("Done task"))
    check("sweep", "moved blocks are in document order",
          join(moved[1].lines):match("Done task one") ~= nil
          and join(moved[2].lines):match("Done task two") ~= nil)
end

do
    local active = lines_of([[
# Current Sprint

- [ ] Nothing done yet]])
    local new_active, moved = core.sweep(active)
    check("sweep", "returns nil, nil when nothing is done", new_active == nil and moved == nil)
end

do
    -- A task's full payload -- including a fence and interior blank lines --
    -- moves as one unit with it.
    local active = lines_of([[
# Sprint

- [x] Task with a fence
    > **Completed:** 2026-09-01
    ```sh
    echo one

    echo two
    ```

- [ ] Still pending]])
    local new_active, moved = core.sweep(active)
    check("sweep", "payload fence and interior blank line move with the task",
          #moved == 1 and join(moved[1].lines):match("echo one\n\n    echo two") ~= nil)
    check("sweep", "pending task and heading remain",
          join(new_active):match("# Sprint") ~= nil and join(new_active):match("Still pending") ~= nil)
end

do
    -- Headings and top-level prose are never swept, even when every task
    -- beneath a heading is done.
    local active = lines_of([[
# Sprint

Some prose about this sprint.

- [x] Only task
    > **Completed:** 2026-09-01]])
    local new_active = core.sweep(active)
    check("sweep", "heading survives when every task beneath it is done",
          join(new_active):match("# Sprint") ~= nil)
    check("sweep", "top-level prose survives when every task beneath it is done",
          join(new_active):match("Some prose") ~= nil)
end

-- ── insert_into_completed() ──────────────────────────────────────────────

do
    local completed = lines_of([[
# Completed Archive]])
    local moved = { { lines = { "- [x] A task", "    > **Completed:** 2026-09-01" } } }
    local result = core.insert_into_completed(completed, moved)
    check("insert_into_completed", "inserts directly beneath the document title with no section heading",
          join(result) == "# Completed Archive\n\n- [x] A task\n    > **Completed:** 2026-09-01", join(result))
end

do
    -- Insertion point is located by position, never by matching heading text.
    local completed = lines_of([[
# Whatever This Heading Says]])
    local moved = { { lines = { "- [x] A task" } } }
    local result = core.insert_into_completed(completed, moved)
    check("insert_into_completed", "inserts after the first heading regardless of its text",
          result[1] == "# Whatever This Heading Says" and result[3] == "- [x] A task")
end

do
    -- Existing tasks in completed.tm.md remain below newly swept tasks.
    local completed = lines_of([[
# Completed Archive

- [x] Earlier task
    > **Completed:** 2026-09-01

- [x] Old task
    > **Completed:** 2026-08-01]])
    local moved = { { lines = { "- [x] New task", "    > **Completed:** 2026-09-02" } } }
    local result = core.insert_into_completed(completed, moved)
    local text = join(result)
    check("insert_into_completed", "new task prepended above existing tasks (reverse chronological)",
          text:match("# Completed Archive\n\n%- %[x%] New task.-Earlier task.-Old task") ~= nil, text)
    check("insert_into_completed", "creates no H2 section headings",
          not text:match("\n## "))
end

do
    -- Multiple tasks swept together are ordered reverse-chronologically by completion date
    local completed = lines_of([[
# Completed Archive]])
    local moved = {
        { lines = { "- [x] Earlier task", "    > **Completed:** 2026-11-02 git:1111111" } },
        { lines = { "- [x] Later task", "    > **Completed:** 2026-11-08 git:2222222" } },
    }
    local result = core.insert_into_completed(completed, moved)
    local text = join(result)
    check("insert_into_completed", "tasks within a sweep batch are ordered reverse-chronologically",
          text:match("Later task.-Earlier task") ~= nil, text)
end

-- ── normalize_blank_lines() ──────────────────────────────────────────────

do
    local lines = { "# H", "", "", "", "- [ ] a", "", "", "- [ ] b", "", "" }
    local out = core.normalize_blank_lines(lines)
    check("normalize_blank_lines", "collapses a run of blank lines to one",
          join(out) == "# H\n\n- [ ] a\n\n- [ ] b")
    check("normalize_blank_lines", "drops trailing blank lines at EOF", out[#out] == "- [ ] b")
end

do
    local lines = {
        "- [ ] a",
        "    ```text",
        "    one",
        "",
        "",
        "    two",
        "    ```",
    }
    local out = core.normalize_blank_lines(lines)
    check("normalize_blank_lines", "two consecutive blank lines inside a payload fence are preserved exactly",
          join(out) == join(lines))
end

do
    local lines = { "- [ ] a", "", "", "- [ ] b" }
    local once = core.normalize_blank_lines(lines)
    local twice = core.normalize_blank_lines(once)
    check("normalize_blank_lines", "idempotent", join(once) == join(twice))
end

-- ── insert_into_completed() without a document title ────────────────────

do
    -- No `# Title`: new tasks are inserted at the top of the file above
    -- any existing content.
    local completed = lines_of([[
- [x] Old task
    > **Completed:** 2026-11-01]])
    local moved = { { lines = { "- [x] New task" } } }
    local text = join(core.insert_into_completed(completed, moved))
    check("insert_into_completed", "no title: new task inserted at top",
          text:match("^%- %[x%] New task\n\n%- %[x%] Old task") ~= nil, text)
end

do
    -- Preamble prose with no headings stays above the inserted task.
    local completed = lines_of("Notes about this archive.")
    local moved = { { lines = { "- [x] New task" } } }
    local text = join(core.insert_into_completed(completed, moved))
    check("insert_into_completed", "no headings: task appended after preamble prose",
          text == "Notes about this archive.\n\n- [x] New task", text)
end

-- ── prepend_blocks() (archive files, newest first) ───────────────────────

do
    local archive = lines_of([[
# Archived Tasks — 2026-01

## Sprint OLDER

- [x] older]])
    local blocks = { { lines = { "## Sprint NEWER", "", "- [x] newer" } } }
    local text = join(core.prepend_blocks(archive, blocks))
    check("prepend_blocks", "new section lands directly beneath the archive title",
          text == "# Archived Tasks — 2026-01\n\n## Sprint NEWER\n\n- [x] newer\n\n## Sprint OLDER\n\n- [x] older", text)
end

-- ── cap_completed (archive aging, pure) ──────────────────────────────────

do
    local completed = lines_of([[
# Completed Archive

- [x] a
    > **Completed:** 2026-08-20

- [x] b
    > **Completed:** 2026-01-01]])
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", keep_min = 1, keep_days = 14 })
    check("cap_completed", "archives the old task past keep_min",
          groups ~= nil and #groups == 1 and #groups[1].blocks == 1)
    check("cap_completed", "kept task remains in completed.tm.md",
          join(nc):match("%- %[x%] a") ~= nil and not join(nc):match("%- %[x%] b"))
    check("cap_completed", "groups by year/month of the task's own Completed date",
          groups and groups[1].year == "2026" and groups[1].month == "01")
end

do
    local completed = lines_of([[
# Completed Archive

- [x] a
    > **Completed:** 2026-08-20

- [x] b
    > **Completed:** 2026-08-25]])
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", keep_min = 1, keep_days = 14 })
    check("cap_completed", "no-op when all tasks are recent", nc == nil and groups == nil)
end

do
    -- Default retention: the 2 newest tasks stay regardless of age;
    -- older ones go once their Completed stamp passes 14 days.
    local completed = lines_of([[
# Completed Archive

- [x] a
    > **Completed:** 2026-08-01

- [x] b
    > **Completed:** 2026-07-01

- [x] c
    > **Completed:** 2026-06-01]])
    local nc, groups = core.cap_completed(completed, { now = "2026-12-01T00:00:00Z" })
    check("cap_completed", "default keep_min is 2 tasks",
          groups ~= nil and #groups == 1 and groups[1].month == "06"
          and join(nc):match("%- %[x%] b") ~= nil and not join(nc):match("%- %[x%] c"))
end

do
    -- Individual-task archiving also works on legacy files with ## headings
    -- and removes any ## heading left empty after its tasks archive.
    local completed = lines_of([[
# Completed Archive

## 2026-08
- [x] a
    > **Completed:** 2026-08-25

- [x] b
    > **Completed:** 2026-08-24

## 2026-01
- [x] c
    > **Completed:** 2026-01-01]])
    local nc, groups = core.cap_completed(completed, { now = "2026-08-27T00:00:00Z" })
    local text = nc and join(nc) or ""
    check("cap_completed", "archives individual task out of legacy section",
          groups ~= nil and #groups == 1 and groups[1].month == "01")
    check("cap_completed", "drops legacy ## heading left empty after archiving",
          not text:match("## 2026%-01") and text:match("## 2026%-08") ~= nil, text)
end

do
    -- max_bytes > 0 archives oldest tasks first even if recent, always
    -- keeping at least 1 newest task.
    local completed = lines_of([[
# Completed Archive

- [x] newest task
    > **Completed:** 2026-08-26

- [x] middle task
    > **Completed:** 2026-08-25

- [x] oldest task
    > **Completed:** 2026-08-24]])
    -- Size of "# Completed Archive\n\n- [x] newest task\n    > **Completed:** 2026-08-26\n" is ~73 bytes.
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", max_bytes = 90 })
    local text = nc and join(nc) or ""
    check("cap_completed max_bytes", "archives middle and oldest recent tasks to fit max_bytes",
          groups ~= nil and #groups == 1 and #groups[1].blocks == 2)
    check("cap_completed max_bytes", "keeps newest task in completed.tm.md",
          text:match("newest task") ~= nil and not text:match("middle task") and not text:match("oldest task"), text)

    -- Even if max_bytes is smaller than the single newest task, at least 1 newest task is kept.
    local nc2, groups2 = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", max_bytes = 10 })
    local text2 = nc2 and join(nc2) or ""
    check("cap_completed max_bytes", "always keeps at least 1 newest task",
          groups2 ~= nil and text2:match("newest task") ~= nil and not text2:match("middle task"), text2)
end

do
    -- Completed stamps inside fenced code blocks or non-4-space indents are ignored.
    local completed = lines_of([[
# Completed Archive

- [x] newest
    > **Completed:** 2026-08-26

- [x] middle
    > **Completed:** 2026-08-25

- [x] fenced stamp task
    ```markdown
    > **Completed:** 2020-01-01
    ```
      > **Completed:** 2020-01-01
    > **Completed:** 2026-08-24]])
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", keep_min = 2, keep_days = 14 })
    check("cap_completed fence", "ignores fenced/mis-indented Completed stamps (task is recent, not 2020-01)",
          nc == nil and groups == nil)
end

do
    -- Multi-level legacy heading cleanup: ## 2026-10 -> ### Week A both removed when emptied.
    local completed = lines_of([[
# Completed Archive

## 2026-08
- [x] a
    > **Completed:** 2026-08-25

- [x] b
    > **Completed:** 2026-08-24

## 2026-10

### Week A
- [x] old
    > **Completed:** 2026-01-01]])
    local nc, groups = core.cap_completed(completed, { now = "2026-08-27T00:00:00Z" })
    local text = nc and join(nc) or ""
    check("cap_completed nested headings", "removes both ### Week A and parent ## 2026-10 when emptied",
          groups ~= nil and not text:match("## 2026%-10") and not text:match("### Week A"), text)
end

do
    -- CRLF size accounting: nl = "\r\n" counts 2 bytes per line ending.
    local completed = lines_of([[
# Completed Archive

- [x] newest
    > **Completed:** 2026-08-26

- [x] older
    > **Completed:** 2026-08-25]])
    -- With \n: "# Completed Archive\n\n- [x] newest\n    > **Completed:** 2026-08-26\n" = 68 bytes.
    -- With \r\n: 4 line endings * 2 = +4 bytes = 72 bytes.
    -- max_bytes = 70 is >= 68 (LF) so LF would keep? Wait: both tasks together are > 70.
    -- With 1 task remaining: LF is 68 <= 70, CRLF is 72 > 70; test that CRLF triggers archiving of older
    -- when total CRLF > max_bytes while total LF would be <= max_bytes.
    local two_lf = #table.concat(completed, "\n") + 1
    local nc_lf = core.cap_completed(completed, { now = "2026-08-27T00:00:00Z", max_bytes = two_lf, nl = "\n" })
    local nc_crlf, groups_crlf = core.cap_completed(completed, { now = "2026-08-27T00:00:00Z", max_bytes = two_lf, nl = "\r\n" })
    check("cap_completed crlf", "LF at exact byte boundary needs no archive", nc_lf == nil)
    check("cap_completed crlf", "CRLF exceeds the same byte boundary and archives older task",
          nc_crlf ~= nil and groups_crlf ~= nil and #groups_crlf == 1)
end

-- ── end-to-end CLI ────────────────────────────────────────────────────────

local function write_file(path, content)
    local f = io.open(path, "w")
    f:write(content)
    f:close()
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return body
end

local function run_cli(args_str)
    local tmsweep = script_dir .. "/../src/tmsweep.lua"
    local cmd = string.format("lua %s %s 2>&1; echo __EXIT__$?", tmsweep, args_str)
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()
    local exit_code = tonumber(output:match("__EXIT__(%d+)")) or -1
    output = output:gsub("__EXIT__%d+%s*$", "")
    return output, exit_code
end

local function tmpdir()
    local dir = "/tmp/tmsweep_e2e_" .. tostring(math.random(100000, 999999))
    os.execute("mkdir -p " .. dir)
    return dir
end

do
    local dir = tmpdir()
    local active = [[
# Current Sprint

- [ ] Pending task

- [x] Done task
    > **Completed:** 2026-09-01]]
    write_file(dir .. "/active.tm.md", active)
    write_file(dir .. "/completed.tm.md", "# Completed Archive")

    local out, code = run_cli(string.format("--sweep %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e sweep", "exit 0", code == 0)
    check("e2e sweep", "reports the swept task",
          out:match('Swept: "Done task"') ~= nil)
    check("e2e sweep", "active.tm.md keeps the pending task and drops the done one",
          (read_file(dir .. "/active.tm.md") or ""):match("Pending task") ~= nil
          and not (read_file(dir .. "/active.tm.md") or ""):match("Done task"))
    check("e2e sweep", "completed.tm.md places the task directly beneath the title with no H2 heading",
          (read_file(dir .. "/completed.tm.md") or ""):find("# Completed Archive\n\n- [x] Done task", 1, true) ~= nil
          and not (read_file(dir .. "/completed.tm.md") or ""):match("\n## "))

    os.execute("rm -rf " .. dir)
end

do
    -- --sprint was removed: passing it is an unknown option error.
    local out, code = run_cli("--sweep --sprint 2026-S2")
    check("e2e sweep --sprint", "--sprint is no longer an option", code ~= 0 and out:match("Unknown option") ~= nil, out)
end

do
    -- Sweeping a file with nothing to sweep changes nothing and exits 0.
    local dir = tmpdir()
    local active = "# Current Sprint\n\n- [ ] Only a pending task"
    write_file(dir .. "/active.tm.md", active)
    write_file(dir .. "/completed.tm.md", "# Completed Archive")

    local out, code = run_cli(string.format("--sweep %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e sweep", "nothing to sweep: exit 0", code == 0)
    check("e2e sweep", "nothing to sweep: active.tm.md unchanged", read_file(dir .. "/active.tm.md") == active)

    os.execute("rm -rf " .. dir)
end

do
    -- --dry-run reports without changing files.
    local dir = tmpdir()
    local active = "# Current Sprint\n\n- [x] Done task\n    > **Completed:** 2026-09-01"
    local completed = "# Completed Archive"
    write_file(dir .. "/active.tm.md", active)
    write_file(dir .. "/completed.tm.md", completed)

    local out, code = run_cli(string.format("--sweep --dry-run %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e sweep dry-run", "exit 0", code == 0)
    check("e2e sweep dry-run", "reports what would move", out:match('Would sweep: "Done task"') ~= nil)
    check("e2e sweep dry-run", "active.tm.md byte-for-byte unchanged", read_file(dir .. "/active.tm.md") == active)
    check("e2e sweep dry-run", "completed.tm.md byte-for-byte unchanged", read_file(dir .. "/completed.tm.md") == completed)

    os.execute("rm -rf " .. dir)
end

do
    -- Rotation was removed in SPEC-TASKMARK-04.
    local out, code = run_cli("--rotate --sprint 2026-S2")
    check("cli", "--rotate is no longer an option", code ~= 0 and out:match("Unknown option") ~= nil, out)
end

do
    -- --archive lands individual tasks under archive/<YYYY>/<YYYY-MM>.tm.md,
    -- newest first beneath the archive title.
    local dir = tmpdir()
    local body = "# Completed Archive\n\n"
    for n = 2, 1, -1 do
        body = body .. string.format("- [x] r%d\n    > **Completed:** 2026-08-2%d\n\n", n, n)
    end
    body = body .. "- [x] newer thing\n    > **Completed:** 2026-01-20\n\n"
    body = body .. "- [x] old thing\n    > **Completed:** 2026-01-15\n"
    write_file(dir .. "/completed.tm.md", body)
    write_file(dir .. "/active.tm.md", "# Current Sprint\n")
    os.execute("mkdir -p " .. dir .. "/archive/2026")
    write_file(dir .. "/archive/2026/2026-01.tm.md", "# Archived Tasks — 2026-01\n\n- [x] oldest\n    > **Completed:** 2026-01-02\n")

    local out, code = run_cli(string.format("--archive %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e archive", "exit 0", code == 0, out)
    check("e2e archive", "reports the archived tasks",
          out:match('Archived task: "old thing"') ~= nil and out:match('Archived task: "newer thing"') ~= nil
          and out:match("2026/2026%-01%.tm%.md") ~= nil, out)
    local archived = read_file(dir .. "/archive/2026/2026-01.tm.md") or ""
    check("e2e archive", "archive file keeps its title first", archived:match("^# Archived Tasks — 2026%-01\n") ~= nil)
    check("e2e archive", "archive file is newest first",
          archived:match("newer thing.-old thing.-oldest") ~= nil, archived)
    local remaining = read_file(dir .. "/completed.tm.md") or ""
    check("e2e archive", "aged tasks removed; 2 newest kept",
          not remaining:match("old thing") and not remaining:match("newer thing") and remaining:match("%- %[x%] r2.-%- %[x%] r1") ~= nil, remaining)

    os.execute("rm -rf " .. dir)
end

do
    -- --archive --max-bytes N trims oldest tasks until completed.tm.md <= N bytes.
    local dir = tmpdir()
    local today = os.date("!%Y-%m-%d")
    local body = "# Completed Archive\n\n"
        .. string.format("- [x] newest\n    > **Completed:** %s\n\n", today)
        .. string.format("- [x] older\n    > **Completed:** %s\n", today)
    write_file(dir .. "/completed.tm.md", body)
    write_file(dir .. "/active.tm.md", "# Current Sprint\n")

    local out, code = run_cli(string.format("--archive --max-bytes 80 %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e archive --max-bytes", "exit 0", code == 0, out)
    local remaining = read_file(dir .. "/completed.tm.md") or ""
    check("e2e archive --max-bytes", "keeps newest task and archives older task",
          remaining:match("newest") ~= nil and not remaining:match("older") and #remaining <= 80, remaining)

    local bad_out, bad_code = run_cli(string.format("--archive --max-bytes nope %s/active.tm.md", dir))
    check("e2e archive --max-bytes", "invalid --max-bytes exits non-zero", bad_code ~= 0, bad_out)

    local no_arch_out, no_arch_code = run_cli(string.format("--sweep --max-bytes 80 %s/active.tm.md", dir))
    check("e2e archive --max-bytes", "--max-bytes without --archive exits non-zero",
          no_arch_code ~= 0 and no_arch_out:find("--max-bytes applies only to --archive", 1, true) ~= nil, no_arch_out)

    -- Dateless tasks keeping file over max_bytes emits a warning on stderr.
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n\n- [x] dateless one\n\n- [x] dateless two\n")
    local w_out_f, w_err_f = dir .. "/w_out.txt", dir .. "/w_err.txt"
    local wp = io.popen(string.format("lua %s/../src/tmsweep.lua --archive --max-bytes 10 %s/active.tm.md %s/completed.tm.md >%s 2>%s; echo $?",
        script_dir, dir, dir, w_out_f, w_err_f))
    local w_code = tonumber(wp:read("*a"):match("(%d+)")) or -1
    wp:close()
    local w_err = read_file(w_err_f) or ""
    check("e2e archive dateless over cap", "exits 0 and warns on stderr",
          w_code == 0 and w_err:match("warning:.*exceeds max_bytes") ~= nil, w_err)

    -- --dry-run also prints the over-cap warning when some tasks would archive.
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n\n"
        .. string.format("- [x] newest task with long title to exceed cap\n    > **Completed:** %s\n\n", today)
        .. string.format("- [x] older task\n    > **Completed:** %s\n", today))
    local dr_out_f, dr_err_f = dir .. "/dr_out.txt", dir .. "/dr_err.txt"
    local drp = io.popen(string.format("lua %s/../src/tmsweep.lua --archive --max-bytes 10 --dry-run %s/active.tm.md %s/completed.tm.md >%s 2>%s; echo $?",
        script_dir, dir, dir, dr_out_f, dr_err_f))
    local dr_code = tonumber(drp:read("*a"):match("(%d+)")) or -1
    drp:close()
    local dr_err = read_file(dr_err_f) or ""
    check("e2e archive dry-run over cap", "warns on stderr even under --dry-run when tasks would archive",
          dr_code == 0 and dr_err:match("warning:.*exceeds max_bytes") ~= nil, dr_err)

    os.execute("rm -rf " .. dir)
end

do
    -- Sweep holds the task-directory lock for its read-modify-write: it
    -- waits for a lock held by another process, and leaves none behind.
    local dir = tmpdir()
    write_file(dir .. "/active.tm.md", "# Current Sprint\n\n- [x] Locked task\n")
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n")
    os.execute(string.format("mkdir %s/.tm.lock && (sleep 0.3; rmdir %s/.tm.lock) &", dir, dir))
    os.execute("sleep 0.05")
    local out, code = run_cli(string.format("--sweep %s/active.tm.md", dir))
    check("lock", "sweep waits for a held lock, then succeeds", code == 0, out)
    check("lock", "sweep moved the task after the lock cleared",
          (read_file(dir .. "/completed.tm.md") or ""):match("Locked task") ~= nil)
    check("lock", "sweep leaves no lock behind", os.execute("test -e " .. dir .. "/.tm.lock") ~= true)

    -- A failing sweep (missing completed.tm.md) dies without a stale lock.
    os.remove(dir .. "/completed.tm.md")
    write_file(dir .. "/active.tm.md", "# Current Sprint\n\n- [x] Another\n")
    out, code = run_cli(string.format("--sweep %s/active.tm.md", dir))
    check("lock", "failing sweep exits non-zero", code ~= 0)
    check("lock", "failing sweep leaves no lock behind", os.execute("test -e " .. dir .. "/.tm.lock") ~= true)
    os.execute("rm -rf " .. dir)

    -- Sweep in an uninitialized directory reports directory does not exist,
    -- not a false lock error, and fails immediately.
    local empty_dir = tmpdir()
    local abs_root = io.popen("cd " .. script_dir .. "/.. && pwd"):read("*l")
    local tmsweep = abs_root .. "/src/tmsweep.lua"
    local t0 = os.time()
    local cmd = string.format("cd %s && lua %s --sweep 2>&1; echo __EXIT__$?", empty_dir, tmsweep)
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()
    local elapsed = os.time() - t0
    local exit_code = tonumber(output:match("__EXIT__(%d+)")) or -1
    output = output:gsub("__EXIT__%d+%s*$", "")
    check("nonexistent_tasks_dir", "sweep in empty directory exits non-zero", exit_code ~= 0)
    check("nonexistent_tasks_dir", "sweep reports directory does not exist",
        output:find("does not exist", 1, true) ~= nil and output:find("locked by another tm process", 1, true) == nil,
        output)
    check("nonexistent_tasks_dir", "sweep fails immediately without lock retry sleep", elapsed < 2)
    os.execute("rm -rf " .. empty_dir)
end

do
    -- Help and unknown-option handling.
    local out, code = run_cli("-h")
    check("cli", "-h exits 0", code == 0)
    check("cli", "-h prints usage", out:match("tmsweep") ~= nil)

    out, code = run_cli("--bogus")
    check("cli", "unknown option: non-zero exit", code ~= 0)
    check("cli", "unknown option: reports it", out:match("Unknown option") ~= nil)

    out, code = run_cli("")
    check("cli", "no action given: non-zero exit", code ~= 0)
end

do
    -- Indented task lines warn on stderr while leaving stdout and exit status unchanged.
    local dir = tmpdir()
    write_file(dir .. "/active.tm.md", "# Current Sprint\n\n  - [x] Indented done\n")
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n")
    local out_f, err_f = dir .. "/stdout.txt", dir .. "/stderr.txt"
    local p = io.popen(string.format("lua %s/src/tmsweep.lua --sweep %s/active.tm.md >%s 2>%s; echo $?",
        script_dir .. "/..", dir, out_f, err_f))
    local code = tonumber(p:read("*a"):match("(%d+)")) or -1
    p:close()
    local out = read_file(out_f) or ""
    local err = read_file(err_f) or ""
    check("indented-warn", "sweep exits 0", code == 0)
    check("indented-warn", "sweep warns on stderr naming file, line, and tm validate",
        err:find("active.tm.md:3", 1, true) ~= nil and err:find("tm validate", 1, true) ~= nil, err)
    check("indented-warn", "sweep keeps stdout free of warnings",
        out:find("warning:", 1, true) == nil, out)
    os.execute("rm -rf " .. dir)
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
