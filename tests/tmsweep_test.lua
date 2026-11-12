#!/usr/bin/env lua
-- tests/tmsweep_test.lua — unit + end-to-end tests for tmsweep_core.lua /
-- tmsweep.lua (SPEC-TASKMARK-05 §5.3-§5.5: task-level sweep, blank-line
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

-- ── boundary_sections ────────────────────────────────────────────────────
-- Groups completed.tm.md by "## Sprint ..." sections, however deeply
-- they're nested under a top H1 -- unaffected by the move to task-level
-- sweep.

do
    local lines = lines_of([[
# Sprint One
- [ ] task a
- [x] task b

# Sprint Two
- [x] task c]])
    local boundaries = core.boundary_sections(lines)
    check("boundary_sections", "flat H1 siblings: two boundaries", #boundaries == 2)
    check("boundary_sections", "flat H1 siblings: titles", boundaries[1] and boundaries[1].title == "Sprint One"
          and boundaries[2] and boundaries[2].title == "Sprint Two")
    check("boundary_sections", "flat H1 siblings: body_end at next header/EOF",
          boundaries[1] and boundaries[1].body_end == 5 and boundaries[2] and boundaries[2].body_end == #lines + 1)
end

do
    local lines = lines_of([[
# Active Sprints

## Sprint A
- [ ] task a

## Sprint B
- [x] task b]])
    local boundaries = core.boundary_sections(lines)
    check("boundary_sections", "H1-wrapping-H2: wrapper has no direct task, recurses into both children",
          #boundaries == 2 and boundaries[1].title == "Sprint A" and boundaries[2].title == "Sprint B")
end

do
    local lines = lines_of([[
## Bootstrap Remediation (Jul 11)

### Speed
- [x] speed task

### Size
- [ ] size task]])
    local boundaries = core.boundary_sections(lines)
    check("boundary_sections", "H2-wrapping-H3: two grandchild boundaries",
          #boundaries == 2 and boundaries[1].title == "Speed" and boundaries[2].title == "Size")
end

do
    local lines = lines_of([[
# Wrapper
## A
- [x] a
## B
- [x] b]])
    local boundaries = core.boundary_sections(lines)
    check("boundary_sections", "wrapper with no direct tasks recurses into children",
          #boundaries == 2 and boundaries[1].title == "A" and boundaries[2].title == "B")
end

do
    local lines = lines_of([[
# Sprint One
- [x] a

# Sprint Two
- [x] b]])
    local boundaries = core.boundary_sections(lines)
    check("boundary_sections", "flat headers owning direct tasks are their own boundaries",
          #boundaries == 2 and boundaries[1].title == "Sprint One" and boundaries[2].title == "Sprint Two")
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
    local result = core.insert_into_completed(completed, moved, "Sprint 2026-S2")
    check("insert_into_completed", "creates a new H2 sprint heading after the first heading",
          join(result):match("# Completed Archive\n\n## Sprint 2026%-S2\n\n%- %[x%] A task") ~= nil)
end

do
    -- Insertion point is located by position, never by matching heading text.
    local completed = lines_of([[
# Whatever This Heading Says]])
    local moved = { { lines = { "- [x] A task" } } }
    local result = core.insert_into_completed(completed, moved, nil)
    check("insert_into_completed", "inserts after the first heading regardless of its text",
          result[1] == "# Whatever This Heading Says" and result[3] == "- [x] A task")
end

do
    -- A section for the current sprint already at the top: append into it
    -- rather than creating a duplicate H2.
    local completed = lines_of([[
# Completed Archive

## Sprint 2026-S2

- [x] Earlier task
    > **Completed:** 2026-09-01

## Sprint 2026-S1

- [x] Old task
    > **Completed:** 2026-08-01]])
    local moved = { { lines = { "- [x] New task", "    > **Completed:** 2026-09-02" } } }
    local result = core.insert_into_completed(completed, moved, "Sprint 2026-S2")
    local text = join(result)
    local _, count = text:gsub("## Sprint 2026%-S2", "")
    check("insert_into_completed", "does not duplicate the existing sprint heading", count == 1)
    check("insert_into_completed", "new task prepended into the existing section (reverse chronological)",
          text:match("New task.-Earlier task") ~= nil)
    check("insert_into_completed", "older sprint section is untouched and still follows",
          text:match("Earlier task.-## Sprint 2026%-S1.-Old task") ~= nil)
end

do
    -- YYYY-MM formatted heading without 'Sprint' prefix
    local completed = lines_of([[
# Completed Archive]])
    local moved = { { lines = { "- [x] A task", "    > **Completed:** 2026-11-08" } } }
    local result = core.insert_into_completed(completed, moved, "2026-11")
    check("insert_into_completed", "uses the heading text exactly as given",
          join(result):match("# Completed Archive\n\n## 2026%-11\n\n%- %[x%] A task") ~= nil)
end

do
    -- No sprint label: no wrapping heading is invented.
    local completed = lines_of([[
# Completed Archive]])
    local moved = { { lines = { "- [x] A task" } } }
    local result = core.insert_into_completed(completed, moved, nil)
    check("insert_into_completed", "omits any sprint heading when no label is given",
          not join(result):match("## Sprint"))
end

do
    -- Multiple tasks swept together are ordered reverse-chronologically by completion date
    local completed = lines_of([[
# Completed Archive

## 2026-11]])
    local moved = {
        { lines = { "- [x] Earlier task", "    > **Completed:** 2026-11-02 git:1111111" } },
        { lines = { "- [x] Later task", "    > **Completed:** 2026-11-08 git:2222222" } },
    }
    local result = core.insert_into_completed(completed, moved, "2026-11")
    local text = join(result)
    check("insert_into_completed", "tasks within a sweep batch are ordered reverse-chronologically",
          text:match("Later task.-Earlier task") ~= nil)
end

do
    -- A new section always goes on top (§6.3), even above sections whose
    -- headings sort after it as text -- e.g. a pre-0.4 file of "## Sprint"
    -- sections, or Sprint S10 after S9.
    local completed = lines_of([[
# Completed Archive

## Sprint 2026-S2

- [x] s2 task

## Sprint 2026-S1

- [x] s1 task]])
    local moved = { { lines = { "- [x] Fresh task" } } }
    local text = join(core.insert_into_completed(completed, moved, "2026-11"))
    check("insert_into_completed", "new month section lands above existing Sprint sections",
          text:match("^# Completed Archive\n\n## 2026%-11\n\n%- %[x%] Fresh task\n\n## Sprint 2026%-S2") ~= nil, text)

    completed = lines_of("# Completed\n\n## Sprint S9\n\n- [x] nine")
    text = join(core.insert_into_completed(completed, { { lines = { "- [x] ten" } } }, "Sprint S10"))
    check("insert_into_completed", "Sprint S10 lands above Sprint S9",
          text:match("## Sprint S10.-## Sprint S9") ~= nil, text)
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

-- ── section_completed_date ───────────────────────────────────────────────

do
    local block = lines_of([[
## Sprint
- [x] a
    > **Completed:** 2026-08-20 git:abc1234
- [x] b
    > **Completed:** 2026-08-27 git:def5678]])
    local core_tmscan = require("tmscan")
    check("section_completed_date", "returns the latest Completed date among tasks",
          core.section_completed_date(block) == core_tmscan.parse_iso8601("2026-08-27"))
    check("section_completed_date", "nil when no task carries a Completed stamp",
          core.section_completed_date(lines_of("# Sprint\n- [x] t")) == nil)
end

-- ── insert_into_completed() without a document title ────────────────────

do
    -- No `# Title`: the first heading is itself the top section. A matching
    -- top section is prepended into, never duplicated.
    local completed = lines_of([[
## 2026-11

- [x] Old task
    > **Completed:** 2026-11-01

## 2026-10

- [x] Older task]])
    local moved = { { lines = { "- [x] New task" } } }
    local text = join(core.insert_into_completed(completed, moved, "2026-11"))
    local _, count = text:gsub("## 2026%-11", "")
    check("insert_into_completed", "no title: existing top section is not duplicated", count == 1, text)
    check("insert_into_completed", "no title: new task prepended into the top section",
          text:match("^## 2026%-11\n\n%- %[x%] New task\n\n%- %[x%] Old task") ~= nil, text)
end

do
    -- No `# Title` and the top section is older: the new section goes
    -- above it, at the top of the file.
    local completed = lines_of([[
## 2026-10

- [x] Older task]])
    local moved = { { lines = { "- [x] New task" } } }
    local text = join(core.insert_into_completed(completed, moved, "2026-11"))
    check("insert_into_completed", "no title: new section inserted above the older one",
          text:match("^## 2026%-11\n\n%- %[x%] New task\n\n## 2026%-10") ~= nil, text)
end

do
    -- Preamble prose with no headings stays above the inserted section.
    local completed = lines_of("Notes about this archive.")
    local moved = { { lines = { "- [x] New task" } } }
    local text = join(core.insert_into_completed(completed, moved, "2026-11"))
    check("insert_into_completed", "no headings: section appended after preamble prose",
          text == "Notes about this archive.\n\n## 2026-11\n\n- [x] New task", text)
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

## A
- [x] a
    > **Completed:** 2026-08-20

## B
- [x] b
    > **Completed:** 2026-01-01]])
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", keep_min = 1, keep_days = 14 })
    check("cap_completed", "archives the old section past keep_min",
          groups ~= nil and #groups == 1 and #groups[1].blocks == 1)
    check("cap_completed", "kept section remains in completed.tm.md",
          join(nc):match("## A") ~= nil and not join(nc):match("## B"))
    check("cap_completed", "groups by year/month of the section's own Completed date",
          groups and groups[1].year == "2026" and groups[1].month == "01")
end

do
    local completed = lines_of([[
# Completed Archive

## A
- [x] a
    > **Completed:** 2026-08-20

## B
- [x] b
    > **Completed:** 2026-08-25]])
    local nc, groups = core.cap_completed(completed,
        { now = "2026-08-27T00:00:00Z", keep_min = 1, keep_days = 14 })
    check("cap_completed", "no-op when all sections are recent", nc == nil and groups == nil)
end

do
    -- Default retention: the 2 newest sections stay regardless of age;
    -- older ones go once their newest Completed stamp passes 14 days.
    local completed = lines_of([[
# Completed Archive

## 2026-08
- [x] a
    > **Completed:** 2026-08-01

## 2026-07
- [x] b
    > **Completed:** 2026-07-01

## 2026-06
- [x] c
    > **Completed:** 2026-06-01]])
    local nc, groups = core.cap_completed(completed, { now = "2026-12-01T00:00:00Z" })
    check("cap_completed", "default keep_min is 2 sections",
          groups ~= nil and #groups == 1 and groups[1].month == "06"
          and join(nc):match("## 2026%-07") ~= nil and not join(nc):match("## 2026%-06"))
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
    local month = os.date("%Y-%m")
    check("e2e sweep", "completed.tm.md gains a ## <sweep month> section with the task",
          (read_file(dir .. "/completed.tm.md") or ""):find("## " .. month .. "\n\n- [x] Done task", 1, true) ~= nil)

    os.execute("rm -rf " .. dir)
end

do
    -- --sprint LABEL buckets the swept tasks under "## Sprint LABEL".
    local dir = tmpdir()
    write_file(dir .. "/active.tm.md", "# Current Sprint\n\n- [x] Sprint task\n")
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n")
    local out, code = run_cli(string.format("--sweep --sprint 2026-S2 %s/active.tm.md", dir))
    check("e2e sweep --sprint", "exit 0", code == 0, out)
    check("e2e sweep --sprint", "tasks bucketed under ## Sprint 2026-S2",
          (read_file(dir .. "/completed.tm.md") or ""):find("## Sprint 2026-S2\n\n- [x] Sprint task", 1, true) ~= nil)
    os.execute("rm -rf " .. dir)
end

do
    -- --sprint always means "## Sprint <label>", whatever the label looks like.
    local dir = tmpdir()
    write_file(dir .. "/completed.tm.md", "# Completed Archive\n")
    for _, label in ipairs({ "2026-11", "Sprint-1" }) do
        write_file(dir .. "/active.tm.md", "# Current Sprint\n\n- [x] task for " .. label .. "\n")
        run_cli(string.format("--sweep --sprint %s %s/active.tm.md", label, dir))
    end
    local body = read_file(dir .. "/completed.tm.md") or ""
    check("e2e sweep --sprint", "date-like label becomes ## Sprint 2026-11", body:find("## Sprint 2026-11\n", 1, true) ~= nil, body)
    check("e2e sweep --sprint", "Sprint-prefixed label becomes ## Sprint Sprint-1", body:find("## Sprint Sprint-1\n", 1, true) ~= nil, body)
    os.execute("rm -rf " .. dir)
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
    -- --archive lands sections under archive/<YYYY>/<YYYY-MM>.tm.md,
    -- newest first beneath the archive title.
    local dir = tmpdir()
    local body = "# Completed Archive\n\n"
    for n = 2, 1, -1 do
        body = body .. string.format("## R%d\n- [x] t\n    > **Completed:** 2026-08-2%d\n\n", n, n)
    end
    body = body .. "## NEWER\n- [x] newer thing\n    > **Completed:** 2026-01-20\n\n"
    body = body .. "## OLD\n- [x] old thing\n    > **Completed:** 2026-01-15\n"
    write_file(dir .. "/completed.tm.md", body)
    write_file(dir .. "/active.tm.md", "# Current Sprint\n")
    os.execute("mkdir -p " .. dir .. "/archive/2026")
    write_file(dir .. "/archive/2026/2026-01.tm.md", "# Archived Tasks — 2026-01\n\n## OLDEST\n- [x] oldest\n    > **Completed:** 2026-01-02\n")

    local out, code = run_cli(string.format("--archive %s/active.tm.md %s/completed.tm.md", dir, dir))
    check("e2e archive", "exit 0", code == 0, out)
    check("e2e archive", "reports the archived sections",
          out:match('Archived section: "OLD"') ~= nil and out:match('Archived section: "NEWER"') ~= nil
          and out:match("2026/2026%-01%.tm%.md") ~= nil, out)
    local archived = read_file(dir .. "/archive/2026/2026-01.tm.md") or ""
    check("e2e archive", "archive file keeps its title first", archived:match("^# Archived Tasks — 2026%-01\n") ~= nil)
    check("e2e archive", "archive file is newest first",
          archived:match("## NEWER.-## OLD\n.-## OLDEST") ~= nil, archived)
    local remaining = read_file(dir .. "/completed.tm.md") or ""
    check("e2e archive", "aged sections removed; 2 newest kept",
          not remaining:match("OLD") and not remaining:match("NEWER") and remaining:match("## R2.-## R1") ~= nil, remaining)

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

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
