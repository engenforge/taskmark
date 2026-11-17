#!/usr/bin/env lua
-- tests/tmmutate_test.lua — unit and CLI tests for tmmutate.lua
-- (SPEC-TASKMARK-06 AI & CLI ergonomics: atomic task mutations, compact
-- listings, and ephemeral hashes).

-- Run hermetically (see tests/tmsync_test.lua): the --git cases make
-- commits in scratch repositories, which must not pick up the user's
-- global, system, or environment-injected git configuration (signing,
-- hooks, identity).
-- Git is optional for building, testing, and installing Taskmark: the
-- --git cases are skipped, and reported, when it isn't installed.

package.path = ((arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local HAVE_GIT = require("testgit").isolate()

local script_dir = (arg[0] or "./tests/tmmutate_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmscan = require("tmscan")
local tmval  = require("tmval")
local tmio   = require("tmio")
local tmmutate = require("tmmutate")

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

local function make_temp_dir()
    local dir = string.format("/tmp/tm_mutate_test_%d_%d", os.time(), math.random(100000, 999999))
    tmio.mkdir_p(dir)
    return dir
end

local function cleanup_dir(dir)
    if dir and dir:match("^/tmp/tm_mutate_test_") then
        os.execute("rm -rf " .. tmio.shell_quote(dir))
    end
end

-- ── 1. find_task & ephemeral hash resolution ───────────────────────────────

do
    local lines = tmscan.lines_of([[
# Current Sprint

- [ ] (A) +io @lua Hardening atomic writes in tmio
    > **Context:** Prevent collision.

- [ ] (B) +spec pure CommonMark transition
    > **Context:** Drop frontmatter.

- [x] (C) Already done task
    > **Completed:** 2026-11-01
]])

    local tasks = tmscan.tasks(lines)
    local t1 = tasks[1]
    local t2 = tasks[2]

    -- Match by 4-char hex prefix
    local h1_4 = t1.hash:sub(1, 4)
    local match, err = tmmutate.find_task(tasks, h1_4)
    check("find_task", "match by 4-char hex prefix", match and match.line == t1.line)

    -- Match by full 8-char hash
    local match_full = tmmutate.find_task(tasks, t1.hash)
    check("find_task", "match by full 8-char hash", match_full and match_full.line == t1.line)

    -- Match with brackets [f4a1]
    local match_bracket = tmmutate.find_task(tasks, "[" .. h1_4 .. "]")
    check("find_task", "match with bracket handle [xxxx]", match_bracket and match_bracket.line == t1.line)

    -- Match by substring pattern
    local match_sub = tmmutate.find_task(tasks, "Hardening atomic")
    check("find_task", "match by substring pattern", match_sub and match_sub.line == t1.line)

    -- Substring pattern case-insensitive
    local match_sub_case = tmmutate.find_task(tasks, "commonmark")
    check("find_task", "match by substring case-insensitive", match_sub_case and match_sub_case.line == t2.line)

    -- Not found
    local match_none, err_none = tmmutate.find_task(tasks, "nonexistent")
    check("find_task", "returns nil when not found", match_none == nil and err_none == "not_found")
end

-- ── 2. Hash collision & ambiguous prefix rejection ──────────────────────────

do
    -- Synthesize two tasks that share the same 4-char prefix
    local sample_tasks = {
        { line = 3, hash = "abcd1234", summary = "First task", description = "First task", done = false },
        { line = 7, hash = "abcd5678", summary = "Second task", description = "Second task", done = false },
        { line = 12, hash = "ffff0000", summary = "Third task", description = "Third task", done = false },
    }

    local match, err, candidates = tmmutate.find_task(sample_tasks, "abcd")
    check("find_task", "rejects ambiguous 4-char prefix", match == nil and err == "ambiguous_hash")
    check("find_task", "returns all colliding candidates", candidates and #candidates == 2)

    -- Disambiguate with 5 characters
    local m1 = tmmutate.find_task(sample_tasks, "abcd1")
    check("find_task", "disambiguates with longer prefix (abcd1)", m1 and m1.hash == "abcd1234")

    local m2 = tmmutate.find_task(sample_tasks, "abcd5")
    check("find_task", "disambiguates with longer prefix (abcd5)", m2 and m2.hash == "abcd5678")
end

do
    -- Ambiguous substring match
    local sample_tasks = {
        { line = 3, hash = "11111111", summary = "Refactor database queries", description = "Refactor database queries", done = false },
        { line = 7, hash = "22222222", summary = "Refactor user authentication", description = "Refactor user authentication", done = false },
    }

    local match, err, candidates = tmmutate.find_task(sample_tasks, "Refactor")
    check("find_task", "rejects ambiguous substring pattern", match == nil and err == "ambiguous_pattern")
    check("find_task", "ambiguous pattern returns candidate matches", candidates and #candidates == 2)
end

-- ── 3. tm list ─────────────────────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local file = tmp .. "/active.tm.md"
    local content = [[# Current Sprint

- [ ] (A) Task one pending
    > **Context:** context one

- [x] (B) Task two done
    > **Completed:** 2026-11-01

- [ ] Task three pending
]]
    tmio.write_file_atomic(file, content)

    -- Test programmatic list
    local pending = tmmutate.format_list(file, { filter = "pending" })
    check("list", "default pending lists only pending tasks", #pending == 2)
    check("list", "pending output starts with [xxxx] handle", pending[1]:match("^%[%x%x%x%x%] %(A%) Task one pending") ~= nil)
    check("list", "pending output excludes payload lines", not pending[1]:match("Context"))
    check("list", "pending output handles unprioritized tasks", pending[2]:match("^%[%x%x%x%x%] Task three pending") ~= nil)

    local all_items = tmmutate.format_list(file, { filter = "all" })
    check("list", "all filter lists both pending and done tasks", #all_items == 3)
    check("list", "all filter marks done tasks with [x]", all_items[2]:match("^%[%x%x%x%x%] %[x%] %(B%) Task two done") ~= nil)
    check("list", "all filter marks pending tasks with [ ]",
        all_items[1]:match("^%[%x%x%x%x%] %[ %] %(A%) Task one pending") ~= nil
            and all_items[3]:match("^%[%x%x%x%x%] %[ %] Task three pending") ~= nil, all_items[1])
    check("list", "pending filter leaves pending tasks unmarked", not pending[1]:find("[ ]", 1, true), pending[1])

    cleanup_dir(tmp)
end

-- ── 4. tm done ─────────────────────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local file = tmp .. "/active.tm.md"
    local initial = [[# Current Sprint

- [ ] (A) Socket timeout handling
    > **Context:** Prevent hanging sockets.
    > **Verify:** Tests pass.

- [ ] Plain task without payload
]]
    tmio.write_file_atomic(file, initial)

    local tasks = tmscan.tasks(tmscan.lines_of(initial))
    local hash1 = tasks[1].hash:sub(1, 4)

    -- Mark task 1 done with --git explicit sha
    local ok, res = tmmutate.done({
        file = file,
        query = hash1,
        git_sha = "abc1234",
        date = "2026-11-08",
    })
    check("done", "marks task done successfully", ok == true)

    local content_after = io.open(file):read("*a")
    check("done", "replaces checkbox with - [x]", content_after:match("%- %[x%] %(A%) Socket timeout handling") ~= nil)
    check("done", "preserves existing payload fields", content_after:match("> %*%*Context:%*%* Prevent hanging sockets%."))
    check("done", "appends Completed field with git sha", content_after:match("> %*%*Completed:%*%* 2026%-11%-08 git:abc1234") ~= nil)

    -- Validates cleanly against spec
    local val_errs = tmval.validate_lines(tmscan.lines_of(content_after))
    check("done", "mutated file passes tmval", #val_errs == 0)

    -- Stamping an already-done task fails cleanly
    local ok2, err2 = tmmutate.done({
        file = file,
        query = hash1,
    })
    check("done", "rejects already completed task", ok2 == false and err2 == "already_completed")

    -- Mark task 2 (no payload) done without git sha
    local tasks_after = tmscan.tasks(tmscan.lines_of(content_after))
    local hash2 = tasks_after[2].hash:sub(1, 4)
    local ok3 = tmmutate.done({
        file = file,
        query = hash2,
        date = "2026-11-08",
    })
    check("done", "marks task without prior payload done", ok3 == true)

    local final_content = io.open(file):read("*a")
    check("done", "creates Completed payload for task without prior payload",
          final_content:match("%- %[x%] Plain task without payload\n    > %*%*Completed:%*%* 2026%-11%-08") ~= nil)

    local val_errs2 = tmval.validate_lines(tmscan.lines_of(final_content))
    check("done", "final content passes tmval", #val_errs2 == 0)

    cleanup_dir(tmp)
end

-- ── 5. tm move ─────────────────────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local future_file = tmp .. "/future.tm.md"
    local active_file = tmp .. "/active.tm.md"

    tmio.write_file_atomic(future_file, [[# Backlog

- [ ] (B) Future candidate task
    > **Context:** Planned for next sprint.
    > **Requirements:** High performance.

- [ ] Another future task
]])

    tmio.write_file_atomic(active_file, [[# Current Sprint

- [ ] (A) Active task in progress
]])

    local f_tasks = tmscan.tasks(tmscan.lines_of(io.open(future_file):read("*a")))
    local hash = f_tasks[1].hash:sub(1, 4)

    local ok, res = tmmutate.move({
        from = future_file,
        to = active_file,
        query = hash,
    })
    check("move", "moves task successfully", ok == true)

    local active_content = io.open(active_file):read("*a")
    local future_content = io.open(future_file):read("*a")

    check("move", "destination file has moved task", active_content:match("%- %[ %] %(B%) Future candidate task") ~= nil)
    check("move", "destination file preserves full payload",
          active_content:match("> %*%*Context:%*%* Planned for next sprint%.\n    > %*%*Requirements:%*%* High performance%.") ~= nil)
    check("move", "source file no longer has moved task", future_content:match("Future candidate task") == nil)
    check("move", "source file retains other tasks", future_content:match("Another future task") ~= nil)

    -- Both files pass tmval
    local val1 = #tmval.validate_lines(tmscan.lines_of(active_content)) == 0
    local val2 = #tmval.validate_lines(tmscan.lines_of(future_content)) == 0
    check("move", "destination passes tmval", val1)
    check("move", "source passes tmval", val2)

    cleanup_dir(tmp)
end

-- ── 6. tm add ──────────────────────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local file = tmp .. "/active.tm.md"
    tmio.write_file_atomic(file, [[# Current Sprint

- [ ] (A) Existing task
]])

    local ok, res = tmmutate.add({
        file = file,
        text = "Brand new CLI mutation command",
        priority = "B",
    })
    check("add", "adds task successfully", ok == true)

    local content = io.open(file):read("*a")
    check("add", "formats priority and task line", content:match("%- %[ %] %(B%) Brand new CLI mutation command") ~= nil)

    -- Adding task under specific section
    local multi_section = [[# Tasks

## Sprint 1

- [ ] S1 task

## Sprint 2

- [ ] S2 task
]]
    tmio.write_file_atomic(file, multi_section)

    local ok2 = tmmutate.add({
        file = file,
        text = "Under Sprint 1 task",
        section = "Sprint 1",
    })
    check("add", "adds task under specified section", ok2 == true)

    local s_content = io.open(file):read("*a")
    check("add", "task placed inside target section before next section",
          s_content:match("## Sprint 1.-Under Sprint 1 task.-## Sprint 2") ~= nil)

    local val_errs = tmval.validate_lines(tmscan.lines_of(s_content))
    check("add", "file passes tmval", #val_errs == 0)

    cleanup_dir(tmp)
end

-- ── 7. CLI End-to-End via `src/tm` ──────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local tasks_dir = tmp .. "/.tasks"
    tmio.mkdir_p(tasks_dir)

    local active_file = tasks_dir .. "/active.tm.md"
    local future_file = tasks_dir .. "/future.tm.md"
    local completed_file = tasks_dir .. "/completed.tm.md"

    tmio.write_file_atomic(active_file, "# Active Tasks\n\n")
    tmio.write_file_atomic(future_file, "# Future Tasks\n\n- [ ] (C) Future item\n    > **Context:** from future\n")
    tmio.write_file_atomic(completed_file, "# Completed Tasks\n\n")

    local tm_cmd = "./src/tm"
    local tm_abs_cli = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")

    -- 1. tm add
    local status = os.execute(string.format("%s add --tasks-dir %s -p A 'First added task' > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir)))
    check("cli", "tm add exits 0", status == 0 or status == true)

    -- 2. tm list
    local p = io.popen(string.format("%s list --tasks-dir %s", tm_cmd, tmio.shell_quote(tasks_dir)))
    local list_out = p:read("*a")
    p:close()
    check("cli", "tm list outputs task handle", list_out:match("^%[[0-9a-z]+%] %(A%) First added task") ~= nil)

    -- tm add stamps an identifier, and that is the handle tm list prints.
    local handle = list_out:match("^%[([0-9a-z]+)%]")

    -- 3. tm done <handle>, with --git HEAD resolved in a scratch repository
    -- (never this source tree, which may be an unpacked tarball).
    local d_status
    if HAVE_GIT then
        os.execute("cd " .. tmio.shell_quote(tmp) .. " && git init -q && git commit -q --allow-empty -m init")
        d_status = os.execute(string.format("cd %s && lua %s done --tasks-dir %s %s --git HEAD > /dev/null",
            tmio.shell_quote(tmp), tmio.shell_quote(tm_abs_cli), tmio.shell_quote(tasks_dir), handle))
    else
        d_status = os.execute(string.format("%s done --tasks-dir %s %s > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir), handle))
    end
    check("cli", "tm done exits 0", d_status == 0 or d_status == true)

    local after_done = io.open(active_file):read("*a")
    check("cli", "task marked done in active.tm.md", after_done:match("%- %[x%] %(A%) First added task") ~= nil)
    if HAVE_GIT then
        check("cli", "task has git: SHA", after_done:match("> %*%*Completed:%*%* %d%d%d%d%-%d%d%-%d%d git:%x+") ~= nil)
    else
        print("[SKIP] cli: tm done --git (git is not installed)")
    end

    -- 4. tm move from future to active
    local p2 = io.popen(string.format("%s list --tasks-dir %s %s", tm_cmd, tmio.shell_quote(tasks_dir), tmio.shell_quote(future_file)))
    local f_out = p2:read("*a")
    p2:close()
    local f_handle = f_out:match("^%[(%x%x%x%x)%]")

    local m_status = os.execute(string.format("%s move --tasks-dir %s %s > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir), f_handle))
    check("cli", "tm move exits 0", m_status == 0 or m_status == true)

    local after_move_active = io.open(active_file):read("*a")
    local after_move_future = io.open(future_file):read("*a")
    check("cli", "moved task present in active.tm.md", after_move_active:match("Future item") ~= nil)
    check("cli", "moved task absent from future.tm.md", after_move_future:match("Future item") == nil)

    -- 5. tm sweep
    local s_status = os.execute(string.format("%s sweep --tasks-dir %s > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir)))
    check("cli", "tm sweep exits 0", s_status == 0 or s_status == true)

    local comp_content = io.open(completed_file):read("*a")
    check("cli", "swept completed task landed in completed.tm.md", comp_content:match("First added task") ~= nil)

    cleanup_dir(tmp)
end

-- ── 8. Review regressions ──────────────────────────────────────────────────

local function write(path, body) tmio.write_file_atomic(path, body) end
local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local b = f:read("*a")
    f:close()
    return b
end
local tm_abs = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")
-- Run tm with `dir` as cwd; returns output, exit code.
local function tm_in(dir, args, env)
    local p = io.popen(string.format("cd %s && %slua %s %s 2>&1; echo __EXIT__$?",
        tmio.shell_quote(dir), env or "", tm_abs, args))
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("__EXIT__(%d+)")) or -1
    return out:gsub("__EXIT__%d+%s*$", ""), code
end
local function git_repo(dir)
    os.execute("cd " .. tmio.shell_quote(dir) ..
        " && git init -q && git commit -q --allow-empty -m init")
    local p = io.popen("cd " .. tmio.shell_quote(dir) .. " && git rev-parse --short HEAD")
    local sha = p:read("*l")
    p:close()
    return assert(sha, "git_repo: could not create a commit in " .. dir)
end

do
    -- Handles spread: summaries that differ only in their last character
    -- must not share a 4-character handle.
    local seen, collided = {}, nil
    for _, base in ipairs({ "Task number ", "Phase ", "Fix bug #" }) do
        for n = 1, 30 do
            local h = tmscan.task_hash("- [ ] " .. base .. n):sub(1, 4)
            if seen[h] then collided = seen[h] .. " / " .. base .. n end
            seen[h] = base .. n
        end
    end
    check("hash", "near-identical summaries get distinct 4-char handles", collided == nil, collided)
end

do
    -- Two tasks sharing a 4-char prefix: list lengthens both handles until
    -- unique, and the longer handle printed by list resolves.
    local by_prefix, a, b = {}, nil, nil
    for n = 1, 100000 do
        local text = "Collision probe " .. n
        local h = tmscan.task_hash("- [ ] " .. text):sub(1, 4)
        if by_prefix[h] then a, b = by_prefix[h], text break end
        by_prefix[h] = text
    end
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    write(tmp .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] " .. a .. "\n\n- [ ] " .. b .. "\n")
    local out = tm_in(tmp, "list")
    local h1, h2 = out:match("^%[(%x+)%] "), out:match("\n%[(%x+)%] ")
    check("list", "colliding handles are lengthened past 4 chars", h1 and h2 and #h1 > 4 and #h2 > 4 and h1 ~= h2, out)

    local amb, code = tm_in(tmp, "done " .. h1:sub(1, 4))
    check("done", "ambiguous 4-char handle is rejected", code ~= 0 and amb:find("Ambiguous", 1, true) ~= nil, amb)
    check("done", "ambiguity message shows a usable longer handle",
        amb:find("[" .. h1 .. "]", 1, true) ~= nil and amb:find("[" .. h2 .. "]", 1, true) ~= nil, amb)

    local _, code2 = tm_in(tmp, "done " .. h2)
    check("done", "lengthened handle from list resolves", code2 == 0)
    check("done", "the right task was completed",
        (read(tmp .. "/.tasks/active.tm.md") or ""):find("- [x] " .. b, 1, true) ~= nil)
    cleanup_dir(tmp)
end

do
    -- done only considers pending tasks; an already-done match is reported, not crashed on.
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    write(tmp .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [x] Fix parser bug\n\n- [ ] Fix parser docs\n")
    local out, code = tm_in(tmp, "done 'Fix parser'")
    check("done", "pattern matching one pending + one done task completes the pending one",
        code == 0 and (read(tmp .. "/.tasks/active.tm.md") or ""):find("- [x] Fix parser docs", 1, true) ~= nil, out)

    write(tmp .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [x] Finished thing\n")
    out, code = tm_in(tmp, "done Finished")
    check("done", "already-completed task: clean error, no crash",
        code == 1 and out:find("already completed", 1, true) ~= nil and not out:find("traceback", 1, true), out)
    cleanup_dir(tmp)
end

if not HAVE_GIT then
    print("[SKIP] done --git: git is not installed; --git parsing cases not run")
else do
    -- --git parsing and validation.
    local tmp = make_temp_dir()
    local sha = git_repo(tmp)
    tmio.mkdir_p(tmp .. "/.tasks")
    local body = "# Current Sprint\n\n- [ ] Target task\n\n- [ ] Other " .. sha .. " mention\n"
    write(tmp .. "/.tasks/active.tm.md", body)

    local out, code = tm_in(tmp, "done --git " .. sha .. " Target")
    local after = read(tmp .. "/.tasks/active.tm.md") or ""
    check("done --git", "--git REV before the query takes REV as the rev",
        code == 0 and after:find("- [x] Target task\n    > **Completed:** " .. os.date("%Y-%m-%d") .. " git:" .. sha, 1, true) ~= nil, out .. after)
    check("done --git", "other task untouched", after:find("- [ ] Other", 1, true) ~= nil)

    write(tmp .. "/.tasks/active.tm.md", body)
    out, code = tm_in(tmp, "done Target --git")
    check("done --git", "trailing bare --git uses HEAD",
        code == 0 and (read(tmp .. "/.tasks/active.tm.md") or ""):find("git:" .. sha, 1, true) ~= nil, out)

    write(tmp .. "/.tasks/active.tm.md", body)
    out, code = tm_in(tmp, "done --git Target")
    check("done --git", "leading bare --git before the query uses HEAD",
        code == 0 and (read(tmp .. "/.tasks/active.tm.md") or ""):find("- [x] Target task\n    > **Completed:** " .. os.date("%Y-%m-%d") .. " git:" .. sha, 1, true) ~= nil, out)

    write(tmp .. "/.tasks/active.tm.md", body)
    out, code = tm_in(tmp, "done Target --git abc")
    check("done --git", "short/unknown rev is rejected", code ~= 0 and read(tmp .. "/.tasks/active.tm.md") == body, out)
    out, code = tm_in(tmp, "done Target --git deadbeefdeadbeef")
    check("done --git", "nonexistent hex rev is rejected", code ~= 0 and read(tmp .. "/.tasks/active.tm.md") == body, out)

    out, code = tm_in(tmp, "done Target extra")
    check("done", "unexpected extra argument is rejected", code ~= 0 and read(tmp .. "/.tasks/active.tm.md") == body, out)
    cleanup_dir(tmp)
end end -- HAVE_GIT

do
    -- Completed goes into the leading field run, and the stamped file validates.
    local tmp = make_temp_dir()
    local f = tmp .. "/active.tm.md"
    write(f, "# S\n\n- [ ] Has notes\n    > **Created:** 2026-11-01\n\n    Some freeform notes.\n")
    tmmutate.done({ file = f, query = "Has notes", date = "2026-11-08" })
    check("done", "Completed joins the leading field run",
        read(f) == "# S\n\n- [x] Has notes\n    > **Created:** 2026-11-01\n    > **Completed:** 2026-11-08\n\n    Some freeform notes.\n", read(f))

    write(f, "# S\n\n- [ ] Freeform only\n    Just notes.\n")
    tmmutate.done({ file = f, query = "Freeform", date = "2026-11-08" })
    local body = read(f)
    check("done", "Completed before freeform-only payload is separated by a blank line",
        body == "# S\n\n- [x] Freeform only\n    > **Completed:** 2026-11-08\n\n    Just notes.\n", body)
    check("done", "stamped freeform-only task validates", #tmval.validate_lines(tmscan.lines_of(body)) == 0)
    cleanup_dir(tmp)
end

do
    -- move within one file, and section placement for add/move.
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    local active = tmp .. "/.tasks/active.tm.md"
    write(active, "# Current Sprint\n\n## Alpha\n\n- [ ] Movable task\n    > **Note:** keep me\n\n## Beta\n\n- [ ] Other\n")
    local out, code = tm_in(tmp, "move Movable --from .tasks/active.tm.md --to .tasks/active.tm.md --section Beta")
    local body = read(active) or ""
    local _, n = body:gsub("Movable task", "")
    check("move", "same-file move keeps exactly one copy", code == 0 and n == 1, out .. body)
    check("move", "same-file move lands in the target section with its payload",
        body:find("## Beta\n\n- [ ] Other\n\n- [ ] Movable task\n    > **Note:** keep me", 1, true) ~= nil, body)

    write(active, "# Current Sprint\n\n## Alpha\n\n- [ ] a\n")
    out, code = tm_in(tmp, "add 'New thing' --section Gamma")
    check("add", "unknown --section is an error and changes nothing",
        code ~= 0 and read(active) == "# Current Sprint\n\n## Alpha\n\n- [ ] a\n" and out:find("Alpha", 1, true) ~= nil, out)

    write(tmp .. "/.tasks/future.tm.md", "# Planned\n\n- [ ] Future thing\n")
    out, code = tm_in(tmp, "move Future --section Gamma")
    check("move", "unknown --section is an error and changes nothing",
        code ~= 0 and (read(tmp .. "/.tasks/future.tm.md") or ""):find("Future thing", 1, true) ~= nil, out)

    write(active, "# Current Sprint\n\n## Alpha\n\n- [ ] a\n\n## Beta\n\n- [ ] b\n")
    tm_in(tmp, "add 'Top level'")
    check("add", "without --section, lands directly under the first heading",
        read(active):gsub(" id:[0-9a-z]+", "") == "# Current Sprint\n\n- [ ] Top level\n\n## Alpha\n\n- [ ] a\n\n## Beta\n\n- [ ] b\n", read(active))

    out, code = tm_in(tmp, "move Future --to .tasks/actve.tm.md")
    check("move", "missing destination is an error, no file created",
        code ~= 0 and read(tmp .. "/.tasks/actve.tm.md") == nil, out)
    out, code = tm_in(tmp, "add Something --file .tasks/nosuch.tm.md")
    check("add", "missing target file is an error, no file created",
        code ~= 0 and read(tmp .. "/.tasks/nosuch.tm.md") == nil, out)
    out, code = tm_in(tmp, "list .tasks/nosuch.tm.md")
    check("list", "missing file is an error", code ~= 0, out)
    cleanup_dir(tmp)

    -- Commands in an uninitialized directory fail immediately reporting directory does not exist
    local empty = make_temp_dir()
    local t0 = os.time()
    out, code = tm_in(empty, "add 'A new task'")
    local elapsed = os.time() - t0
    check("add", "empty dir: reports directory does not exist",
        code ~= 0 and out:find("does not exist", 1, true) ~= nil and out:find("locked by another tm process", 1, true) == nil,
        out)
    check("add", "empty dir: fails immediately without lock retry sleep", elapsed < 2)

    t0 = os.time()
    out, code = tm_in(empty, "done 1234")
    elapsed = os.time() - t0
    check("done", "empty dir: reports directory does not exist",
        code ~= 0 and out:find("does not exist", 1, true) ~= nil and out:find("locked by another tm process", 1, true) == nil,
        out)
    check("done", "empty dir: fails immediately without lock retry sleep", elapsed < 2)
    cleanup_dir(empty)
end

-- ── 9. Second review regressions ───────────────────────────────────────────

do
    -- An existing-Completed search must not reach into fenced example text.
    local tmp = make_temp_dir()
    local f = tmp .. "/active.tm.md"
    write(f, "# S\n\n- [ ] Doc example\n    > **Created:** 2026-11-01\n\n    ```markdown\n    > **Completed:** 2020-01-01 git:deadbee\n    ```\n")
    tmmutate.done({ file = f, query = "Doc example", date = "2026-11-08" })
    check("done", "fenced example line is left untouched, real field run is stamped",
        read(f) == "# S\n\n- [x] Doc example\n    > **Created:** 2026-11-01\n    > **Completed:** 2026-11-08\n\n    ```markdown\n    > **Completed:** 2020-01-01 git:deadbee\n    ```\n", read(f))
    cleanup_dir(tmp)
end

do
    -- Two spellings of one directory, and a symlinked name for the same
    -- file: no self-deadlock, no lost task -- with or without realpath(1).
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    tmio.mkdir_p(tmp .. "/fakebin")
    write(tmp .. "/fakebin/realpath", "#!/bin/sh\nexit 1\n")
    os.execute("chmod +x " .. tmp .. "/fakebin/realpath")
    local body = "# S\n\n## Alpha\n\n- [ ] Movable task\n\n## Beta\n\n- [ ] Other\n"
    for _, case in ipairs({
        { name = "./-prefixed spelling", to = "./.tasks/active.tm.md" },
        { name = "symlink in the same directory", to = ".tasks/current.tm.md", link = true },
    }) do
        for _, env in ipairs({ "", "PATH=" .. tmp .. "/fakebin:$PATH " }) do
            os.remove(tmp .. "/.tasks/current.tm.md")
            write(tmp .. "/.tasks/active.tm.md", body)
            if case.link then os.execute("ln -s active.tm.md " .. tmp .. "/.tasks/current.tm.md") end
            local out, code = tm_in(tmp, "move Movable --from .tasks/active.tm.md --to " .. case.to .. " --section Beta", env)
            local after = read(tmp .. "/.tasks/active.tm.md") or ""
            local _, n = after:gsub("Movable task", "")
            check("move", "same file via " .. case.name .. (env ~= "" and " (no realpath)" or "") .. ": one copy, in Beta",
                code == 0 and n == 1 and after:find("## Beta\n\n- [ ] Other\n\n- [ ] Movable task", 1, true) ~= nil, out .. after)
        end
    end
    cleanup_dir(tmp)
end

do
    -- `--` ends options, so task text and patterns may start with '-'.
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    write(tmp .. "/.tasks/active.tm.md", "# S\n")
    local out, code = tm_in(tmp, "add -p A -- '-v flag handling'")
    check("add", "text after -- may start with '-'", code == 0 and read(tmp .. "/.tasks/active.tm.md"):gsub(" id:[0-9a-z]+", "") == "# S\n\n- [ ] (A) -v flag handling\n", out)
    out, code = tm_in(tmp, "done -- -v")
    check("done", "pattern after -- may start with '-'", code == 0 and (read(tmp .. "/.tasks/active.tm.md") or ""):find("- [x] (A) -v flag", 1, true) ~= nil, out)
    cleanup_dir(tmp)
end

do
    -- Writing through a symlinked task file updates its target and keeps the link.
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    tmio.mkdir_p(tmp .. "/shared")
    write(tmp .. "/shared/active.tm.md", "# S\n\n- [ ] Linked task\n")
    os.execute("ln -s ../shared/active.tm.md " .. tmp .. "/.tasks/active.tm.md")
    local out, code = tm_in(tmp, "done Linked")
    local is_link = os.execute("test -h " .. tmp .. "/.tasks/active.tm.md")
    check("symlink", "tm done through a symlink succeeds", code == 0, out)
    check("symlink", "the symlink is still a symlink", is_link == true or is_link == 0)
    check("symlink", "the link target holds the change",
        (read(tmp .. "/shared/active.tm.md") or ""):find("- [x] Linked task", 1, true) ~= nil)
    cleanup_dir(tmp)
end

-- ── 10. tm list says when there is nothing to list ─────────────────────────

do
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    -- Run tm list with stdout and stderr captured separately.
    local function list(args)
        local errf = tmp .. "/stderr.txt"
        local p = io.popen(string.format("cd %s && lua %s list %s 2>%s; echo __EXIT__$?",
            tmio.shell_quote(tmp), tm_abs, args, tmio.shell_quote(errf)))
        local out = p:read("*a")
        p:close()
        local code = tonumber(out:match("__EXIT__(%d+)")) or -1
        return out:gsub("__EXIT__%d+%s*$", ""), read(errf) or "", code
    end

    write(tmp .. "/.tasks/active.tm.md", "# S\n\n- [x] Finished\n")
    local out, err, code = list("")
    check("list", "no pending tasks: stdout stays empty, exit 0", out == "" and code == 0, out)
    check("list", "no pending tasks: a note on stderr names the file",
        err:find("no pending tasks in .tasks/active.tm.md", 1, true) ~= nil, err)

    out, err = list("--all")
    check("list", "--all with only completed tasks lists them, no note", out:find("[x] Finished", 1, true) ~= nil and err == "", err)

    write(tmp .. "/.tasks/active.tm.md", "# S\n")
    out, err = list("--all")
    check("list", "--all on a file with no tasks: note says no tasks", out == "" and err:find("no tasks in", 1, true) ~= nil, err)

    write(tmp .. "/.tasks/active.tm.md", "# S\n\n- [ ] Pending\n")
    write(tmp .. "/.tasks/future.tm.md", "# P\n")
    out, err = list(".tasks/active.tm.md .tasks/future.tm.md")
    check("list", "several files: only the empty one gets a note",
        out:find("Pending", 1, true) ~= nil and err:find("future.tm.md", 1, true) ~= nil
        and not err:find("active.tm.md", 1, true), err)

    out, err = list("")
    check("list", "pending tasks: no note", err == "", err)
    cleanup_dir(tmp)
end

-- ── Identifiers (§4.3.3): stamping, handles, tm id ─────────────────────────

local function sequence(...)
    local ids, n = { ... }, 0
    return function() n = n + 1; return ids[n] end
end

do
    local tmp = make_temp_dir()
    local active, future = tmp .. "/active.tm.md", tmp .. "/future.tm.md"
    write(active, "# Current Sprint\n\n- [ ] Existing task id:aaaaa\n")
    write(future, "# Planned Work\n\n- [ ] Later task\n    > **Depends:** id:bbbbb\n")

    local ok, res, handles = tmmutate.add({ tasks_dir = tmp, text = "New task", priority = "B",
        generate = sequence("aaaaa", "bbbbb", "ccccc") })
    local content = read(active)
    check("id", "add stamps an identifier unused in any task file",
        ok and content:find("- [ ] (B) New task id:ccccc\n", 1, true) ~= nil, content)
    check("id", "add reports the identifier as the handle", ok and handles[res] == "ccccc")

    tmmutate.add({ tasks_dir = tmp, text = "Hand numbered id:z0114", generate = sequence("ddddd") })
    check("id", "add keeps an identifier already in the text",
        read(active):find("- [ ] Hand numbered id:z0114\n", 1, true) ~= nil)

    local dup_ok, dup_why = tmmutate.add({ tasks_dir = tmp, text = "Reuses a cited one id:bbbbb" })
    check("id", "add refuses a supplied identifier that is already in use",
        dup_ok == false and tostring(dup_why):find("id:bbbbb is already in use", 1, true) ~= nil
        and not read(active):find("Reuses", 1, true), dup_why)
    check("id", "a supplied identifier that only extends a used one is accepted",
        tmmutate.add({ tasks_dir = tmp, text = "Longer id:z01140" }) == true)

    local ok_real = tmmutate.add({ tasks_dir = tmp, text = "Random draw" })
    check("id", "add draws a five-character identifier by default",
        ok_real and read(active):match("%- %[ %] Random draw id:[0-9a-z][0-9a-z][0-9a-z][0-9a-z][0-9a-z]\n") ~= nil)

    local failed_ok, why = tmmutate.add({ tasks_dir = tmp, text = "No entropy",
        generate = function() return nil, "no entropy" end })
    check("id", "add fails, and writes nothing, when no identifier can be drawn",
        failed_ok == false and tostring(why):find("no entropy", 1, true) ~= nil
        and not read(active):find("No entropy", 1, true))
    cleanup_dir(tmp)
end

do
    local lines = tmscan.lines_of("# S\n\n- [ ] First id:k7q2x\n\n- [ ] Second\n\n- [ ] Twin id:dup01\n\n- [ ] Twin two id:dup01\n")
    local tasks = tmscan.tasks(lines)
    local handles = tmmutate.handles(tasks)
    check("id", "a task's identifier is its handle", handles[tasks[1]] == "k7q2x")
    check("id", "a task without one keeps its hash handle", handles[tasks[2]] == tasks[2].hash:sub(1, #handles[tasks[2]]))
    check("id", "a duplicated identifier falls back to hash handles",
        handles[tasks[3]] ~= "dup01" and handles[tasks[3]] ~= handles[tasks[4]])
    check("id", "find_task by identifier", tmmutate.find_task(tasks, "k7q2x") == tasks[1])
    check("id", "find_task by id:-prefixed identifier", tmmutate.find_task(tasks, "id:k7q2x") == tasks[1])
    local none, err, cands = tmmutate.find_task(tasks, "dup01")
    check("id", "a duplicated identifier is ambiguous", none == nil and err == "ambiguous_hash" and #cands == 2)
    local listed = tmmutate.format_list(lines)
    check("id", "list shows the identifier as the handle", listed[1] == "[k7q2x] First id:k7q2x", listed[1])
end

do
    local tmp = make_temp_dir()
    local active, future = tmp .. "/active.tm.md", tmp .. "/future.tm.md"
    write(active, "# S\n\n- [ ] One\n    > **Notes:** detail\n\n- [ ] Two id:aaaaa\n\n- [x] Three\n    > **Completed:** 2026-11-01\n")
    write(future, "# P\n\n- [ ] (A) Four\n")
    write(tmp .. "/completed.tm.md", "# C\n\n- [x] Old\n    > **Completed:** 2026-10-01\n")

    local ok, stamped = tmmutate.stamp({ tasks_dir = tmp, generate = sequence("aaaaa", "bbbbb", "ccccc") })
    check("stamp", "stamps each pending task that lacks an identifier",
        ok and #stamped == 2 and stamped[1].id == "bbbbb" and stamped[2].id == "ccccc")
    check("stamp", "appends to the task line and leaves the payload alone",
        read(active):find("- [ ] One id:bbbbb\n    > **Notes:** detail\n", 1, true) ~= nil, read(active))
    check("stamp", "keeps the priority flag and covers future.tm.md",
        read(future):find("- [ ] (A) Four id:ccccc\n", 1, true) ~= nil)
    check("stamp", "leaves identified and completed tasks unchanged",
        read(active):find("- [ ] Two id:aaaaa\n", 1, true) ~= nil and read(active):find("- [x] Three\n", 1, true) ~= nil
        and read(tmp .. "/completed.tm.md"):find("- [x] Old\n", 1, true) ~= nil)
    check("stamp", "stamped files pass tmval",
        #tmval.validate_lines(tmscan.lines_of(read(active))) == 0)

    local ok2, again = tmmutate.stamp({ tasks_dir = tmp, generate = sequence("ddddd") })
    check("stamp", "a second run stamps nothing", ok2 and #again == 0)

    write(future, "# P\n\n- [ ] (A) Four id:ccccc\n\n- [ ] Copy id:aaaaa\n")
    local _, _, dups = tmmutate.stamp({ tasks_dir = tmp })
    check("stamp", "reports identifiers carried by two tasks", #dups == 1 and dups[1].id == "aaaaa")
    cleanup_dir(tmp)
end

-- ── Tag filters and tm next (§5.1) ─────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local active = tmp .. "/active.tm.md"
    write(active, [[# Current Sprint

- [ ] +api @backend Blocked by parser id:aaaaa
    > **Depends:** id:bbbbb

- [ ] @review +api Awaiting review id:ccccc

- [ ] +parser @backend Write the parser id:bbbbb

- [ ] Follow-up on archived work id:ddddd
    > **Depends:** id:eeeee

- [ ] (B) +api @cli Urgent flag id:fffff

- [ ] Cites a missing task id:ggggg
    > **Depends:** id:zzzzz

- [x] +api Finished id:hhhhh
    > **Completed:** 2026-11-01
]])
    write(tmp .. "/completed.tm.md", "# C\n\n- [x] Archived work id:eeeee\n    > **Completed:** 2026-10-01\n")

    local function ids(items)
        local out = {}
        for _, item in ipairs(items) do out[#out + 1] = item:match("^%[(%w+)%]") end
        return table.concat(out, " ")
    end

    check("filter", "a +project tag selects tasks carrying it",
        ids(tmmutate.format_list(active, { tags = { "+api" } })) == "aaaaa ccccc fffff")
    check("filter", "several tags must all match",
        ids(tmmutate.format_list(active, { tags = { "+api", "@backend" } })) == "aaaaa")
    check("filter", "tags match anywhere on the line, as whole words",
        ids(tmmutate.format_list(active, { tags = { "@review" } })) == "ccccc"
        and ids(tmmutate.format_list(active, { tags = { "+ap" } })) == "")
    check("filter", "--not excludes a tag",
        ids(tmmutate.format_list(active, { tags = { "+api" }, not_tags = { "@review" } })) == "aaaaa fffff")
    check("filter", "filters combine with --all",
        ids(tmmutate.format_list(active, { filter = "all", tags = { "+api" }, not_tags = { "@backend" } })) == "ccccc fffff hhhhh")

    local task, _, warnings = tmmutate.next({ tasks_dir = tmp })
    check("next", "a priority flag is taken ahead of position", task and task.summary:find("id:fffff", 1, true) ~= nil)
    check("next", "a dependency on an unknown identifier is reported",
        #warnings == 1 and warnings[1]:find("id:zzzzz", 1, true) ~= nil, warnings[1])

    task = tmmutate.next({ tasks_dir = tmp, not_tags = { "@cli" } })
    check("next", "otherwise the first task in file order with no unmet dependency",
        task and task.summary:find("id:ccccc", 1, true) ~= nil, task and task.summary)

    task = tmmutate.next({ tasks_dir = tmp, not_tags = { "@cli", "@review" } })
    check("next", "a pending dependency blocks; the dependency itself is ready",
        task and task.summary:find("id:bbbbb", 1, true) ~= nil, task and task.summary)

    task = tmmutate.next({ tasks_dir = tmp, not_tags = { "@cli", "@review", "@backend" } })
    check("next", "a dependency completed in another file is met",
        task and task.summary:find("id:ddddd", 1, true) ~= nil, task and task.summary)

    task = tmmutate.next({ tasks_dir = tmp, tags = { "+api", "@backend" } })
    check("next", "nothing ready: nil", task == nil)

    tmmutate.done({ tasks_dir = tmp, query = "bbbbb", date = "2026-11-12" })
    task = tmmutate.next({ tasks_dir = tmp, tags = { "+api", "@backend" } })
    check("next", "completing the dependency unblocks the dependant",
        task and task.summary:find("id:aaaaa", 1, true) ~= nil)
    cleanup_dir(tmp)
end

-- ── CLI: identifiers, filters, next ────────────────────────────────────────

do
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    write(tmp .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] +api @review First\n\n- [ ] +api Second\n")
    write(tmp .. "/.tasks/future.tm.md", "# Planned Work\n\n- [ ] Later\n")

    local out, code = tm_in(tmp, "add 'Third task'")
    local id = out:match("^Added: %[([0-9a-z]+)%] Third task id:")
    check("cli", "add prints the new identifier as the handle",
        code == 0 and id and #id == 5 and out:find("id:" .. id, 1, true) ~= nil, out)

    out, code = tm_in(tmp, "id")
    local _, stamped = out:gsub("Stamped: %[[0-9a-z]+%]", "")
    check("cli", "id stamps pending tasks in active and future", code == 0 and stamped == 3, out)
    check("cli", "id leaves every pending task identified", (function()
        for _, f in ipairs({ "active", "future" }) do
            for line in read(tmp .. "/.tasks/" .. f .. ".tm.md"):gmatch("[^\n]+") do
                if line:match("^%- %[ %]") and not line:match(" id:[0-9a-z]+$") then return false end
            end
        end
        return true
    end)())
    out, code = tm_in(tmp, "id")
    check("cli", "id with nothing to stamp says so", code == 0 and out:find("Nothing to stamp", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "list +api")
    local _, n = out:gsub("\n", "")
    check("cli", "list filters by tag", code == 0 and n == 2 and not out:find("Third", 1, true), out)
    out = tm_in(tmp, "list +api --not @review")
    check("cli", "list --not excludes a tag", out:find("Second", 1, true) ~= nil and not out:find("First", 1, true), out)
    out = tm_in(tmp, "list @review .tasks/active.tm.md .tasks/future.tm.md")
    check("cli", "list takes tags and files together",
        out:find("First", 1, true) ~= nil and out:find("== .tasks/future.tm.md", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "next --not @review")
    check("cli", "next prints the one task to start", code == 0 and out:match("^%[[0-9a-z]+%] %+api Second id:[0-9a-z]+\n$") ~= nil, out)
    out, code = tm_in(tmp, "next @nowhere")
    check("cli", "next with nothing ready: exit 0 and a note", code == 0 and out:find("no task is ready", 1, true) ~= nil, out)

    local second = read(tmp .. "/.tasks/active.tm.md"):match("Second id:([0-9a-z]+)")
    out, code = tm_in(tmp, "done id:" .. second)
    check("cli", "done accepts an identifier", code == 0 and out:find("Completed: [" .. second .. "]", 1, true) ~= nil, out)

    write(tmp .. "/.tasks/future.tm.md", "# Planned Work\n\n- [ ] Copy id:" .. second .. "\n")
    out, code = tm_in(tmp, "id")
    check("cli", "id warns about an identifier on two tasks",
        code == 0 and out:find("id:" .. second .. " is carried by 2 tasks", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "help")
    check("cli", "help lists id and next", out:find("\n  id ", 1, true) ~= nil and out:find("\n  next ", 1, true) ~= nil)
    cleanup_dir(tmp)
end

-- ── Placement: --before / --after (§5.1) ──────────────────────────────────

do
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    local active, future = tmp .. "/.tasks/active.tm.md", tmp .. "/.tasks/future.tm.md"
    local base = "# Current Sprint\n\n## Now\n\n- [ ] First id:aaaaa\n    > **Notes:** keep\n\n- [ ] Second id:bbbbb\n\n## Next\n\n- [ ] Third id:ccccc\n"
    local function order()
        local out = {}
        for line in read(active):gmatch("[^\n]+") do
            local word = line:match("^%- %[.%] (%S+)") or line:match("^## (%S+)")
            if word then out[#out + 1] = word end
        end
        return table.concat(out, " ")
    end

    write(active, base)
    local ok = tmmutate.add({ tasks_dir = tmp .. "/.tasks", text = "Blocker id:ddddd", before = "bbbbb" })
    check("place", "add --before puts the task directly above the named task",
        ok and order() == "Now First Blocker Second Next Third", order())
    check("place", "the payload above stays with its task",
        read(active):find("First id:aaaaa\n    > **Notes:** keep\n\n- [ ] Blocker", 1, true) ~= nil, read(active))

    ok = tmmutate.add({ tasks_dir = tmp .. "/.tasks", text = "Follow-up id:eeeee", after = "aaaaa" })
    check("place", "add --after puts the task directly below the named task's payload",
        ok and order() == "Now First Follow-up Blocker Second Next Third", order())
    check("place", "result passes tmval", #tmval.validate_lines(tmscan.lines_of(read(active))) == 0)

    ok = tmmutate.add({ tasks_dir = tmp .. "/.tasks", text = "Into next id:fffff", before = "Third" })
    check("place", "an anchor may be a pattern, and crosses headings", ok and order():find("Next Into Third", 1, true) ~= nil, order())

    local before = read(active)
    local bad, why = tmmutate.add({ tasks_dir = tmp .. "/.tasks", text = "Lost id:ggggg", before = "nosuch" })
    check("place", "an unknown anchor is an error and changes nothing", bad == false and why == "not_found" and read(active) == before)
    bad, why = tmmutate.add({ tasks_dir = tmp .. "/.tasks", text = "Both id:hhhhh", before = "aaaaa", section = "Now" })
    check("place", "--before with --section is refused", bad == false and tostring(why):find("--section", 1, true) ~= nil, why)

    write(active, base)
    write(future, "# Planned Work\n\n- [ ] Promote me id:mmmmm\n    > **Notes:** payload\n")
    ok = tmmutate.move({ tasks_dir = tmp .. "/.tasks", query = "mmmmm", before = "bbbbb" })
    check("place", "move --before places the moved task above the named one",
        ok and order() == "Now First Promote Second Next Third" and read(active):find("Promote me id:mmmmm\n    > **Notes:** payload\n", 1, true) ~= nil, order())

    ok = tmmutate.move({ tasks_dir = tmp .. "/.tasks", query = "ccccc", from = active, to = active, after = "aaaaa" })
    check("place", "move --after within one file reorders", ok and order() == "Now First Third Promote Second Next", order())
    bad, why = tmmutate.move({ tasks_dir = tmp .. "/.tasks", query = "ccccc", from = active, to = active, after = "ccccc" })
    check("place", "a task cannot be placed relative to itself", bad == false and tostring(why):find("itself", 1, true) ~= nil, why)

    local out, code = tm_in(tmp, "add 'CLI blocker id:nnnnn' --before bbbbb")
    check("place", "CLI add --before", code == 0 and order():find("CLI Second", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "move ccccc --from .tasks/active.tm.md --to .tasks/active.tm.md --after bbbbb")
    check("place", "CLI move --after", code == 0 and order():find("Second Third", 1, true) ~= nil, out .. order())
    cleanup_dir(tmp)
end

-- ── 9. tm move: inferred source and destination ───────────────────────────

do
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    local active, future = tmp .. "/.tasks/active.tm.md", tmp .. "/.tasks/future.tm.md"
    local base = "# Now\n\n- [ ] First id:aaaaa\n\n- [ ] Second id:bbbbb\n\n- [ ] Third id:ccccc\n"
    local function order()
        local names = {}
        for line in (read(active) or ""):gmatch("%- %[ %] (%S+)") do names[#names + 1] = line end
        return table.concat(names, " ")
    end
    write(active, base)
    write(future, "# Planned\n\n- [ ] Later id:ddddd\n")
    local dir = { tasks_dir = tmp .. "/.tasks" }

    -- Source: not in future.tm.md, so found in active.tm.md.
    local ok, _, _, info = tmmutate.move({ tasks_dir = dir.tasks_dir, query = "ccccc", before = "aaaaa" })
    check("move-infer", "task absent from future is found in active and reordered",
        ok == true and order() == "Third First Second", order())
    check("move-infer", "info reports a same-file move", info and info.same == true and info.from == active, info and info.from)

    -- Destination follows the anchor, even when it is in future.tm.md.
    write(active, base)
    ok = tmmutate.move({ tasks_dir = dir.tasks_dir, query = "ddddd", after = "bbbbb" })
    check("move-infer", "promotion with an anchor in active lands beside it",
        ok and order() == "First Second Later Third", order())

    write(active, base)
    write(future, "# Planned\n\n- [ ] Later id:ddddd\n\n- [ ] Sooner id:eeeee\n")
    ok = tmmutate.move({ tasks_dir = dir.tasks_dir, query = "eeeee", before = "ddddd" })
    check("move-infer", "anchor in future makes a within-future reorder",
        ok and read(future):find("Sooner id:eeeee.-Later id:ddddd") ~= nil and order() == "First Second Third", read(future))

    -- future wins when the task is in both files.
    write(active, base .. "\n- [ ] Both id:fffff\n")
    write(future, "# Planned\n\n- [ ] Both id:ggggg\n")
    ok = tmmutate.move({ tasks_dir = dir.tasks_dir, query = "Both" })
    check("move-infer", "a match in future.tm.md takes precedence over active",
        ok and read(future):find("Both", 1, true) == nil, read(future))

    -- Already in active with nowhere to go is an error, nothing changes.
    write(active, base)
    write(future, "# Planned\n\n- [ ] Later id:ddddd\n")
    local bad, why = tmmutate.move({ tasks_dir = dir.tasks_dir, query = "ccccc" })
    check("move-infer", "a task already in the destination needs a placement",
        bad == false and tostring(why):find("already in", 1, true) ~= nil and read(active) == base, why)

    -- Not found names the files searched and hints at --from.
    local out, code = tm_in(tmp, "move nosuchtask")
    check("move-infer", "not-found names the searched files and --from",
        code ~= 0 and out:find("future.tm.md", 1, true) ~= nil and out:find("active.tm.md", 1, true) ~= nil
        and out:find("--from", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "move nosuchtask --from .tasks/active.tm.md")
    check("move-infer", "not-found with explicit --from names only that file",
        code ~= 0 and out:find("active.tm.md", 1, true) ~= nil and out:find("future.tm.md", 1, true) == nil, out)

    -- CLI output names the source file only when it differs from the destination.
    out, code = tm_in(tmp, "move ddddd")
    check("move-infer", "cross-file move names its source file",
        code == 0 and out:find("(from future.tm.md)", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "move ccccc --before aaaaa")
    check("move-infer", "same-file move does not mention a source",
        code == 0 and out:find("Moved:", 1, true) ~= nil and out:find("from", 1, true) == nil, out)
    cleanup_dir(tmp)
end

-- ── Indented task line warning across list, next, id, add, done, move ──────

do
    local tmp = make_temp_dir()
    git_repo(tmp)
    assert(tm_in(tmp, "init") and true)
    local active = tmp .. "/.tasks/active.tm.md"
    local future = tmp .. "/.tasks/future.tm.md"
    write(active, "# Sprint\n\n  - [ ] Indented task id:abcde\n")
    write(future, "# Planned\n\n- [ ] Planned task\n")

    local function run_split(args)
        local out_f, err_f = tmp .. "/stdout.txt", tmp .. "/stderr.txt"
        local p = io.popen(string.format("cd %s && lua %s %s >%s 2>%s; echo $?",
            tmio.shell_quote(tmp), tm_abs, args, tmio.shell_quote(out_f), tmio.shell_quote(err_f)))
        local code = tonumber(p:read("*a"):match("(%d+)")) or -1
        p:close()
        return read(out_f) or "", read(err_f) or "", code
    end

    local function has_warn(err)
        return err:find("active.tm.md:3", 1, true) ~= nil and err:find("tm validate", 1, true) ~= nil
            and err:find("was skipped", 1, true) == nil
    end
    local function count_substr(s, sub)
        local n, i = 0, 1
        while true do
            local j = s:find(sub, i, true)
            if not j then return n end
            n, i = n + 1, j + #sub
        end
    end

    local out, err, code = run_split("list")
    check("indented-warn", "list warns on stderr, keeps stdout empty and exits 0",
        code == 0 and out == "" and has_warn(err), "err=" .. err .. " out=" .. out)

    out, err, code = run_split("next")
    check("indented-warn", "next warns on stderr, keeps stdout clean and exits 0",
        code == 0 and out == "" and has_warn(err), "err=" .. err .. " out=" .. out)

    out, err, code = run_split("id")
    check("indented-warn", "id warns on stderr and exits 0",
        code == 0 and has_warn(err), "err=" .. err)

    out, err, code = run_split('add "New task"')
    check("indented-warn", "add warns on stderr, writes stdout and exits 0",
        code == 0 and out:find("Added:", 1, true) ~= nil and has_warn(err), "err=" .. err .. " out=" .. out)

    out, err, code = run_split('done "New task"')
    check("indented-warn", "done warns on stderr, writes stdout and exits 0",
        code == 0 and out:find("Completed:", 1, true) ~= nil and has_warn(err), "err=" .. err .. " out=" .. out)

    out, err, code = run_split('move "Planned task"')
    check("indented-warn", "move warns on stderr, writes stdout and exits 0",
        code == 0 and out:find("Moved:", 1, true) ~= nil and has_warn(err), "err=" .. err .. " out=" .. out)
    check("indented-warn", "move warns once per file for active.tm.md",
        count_substr(err, "active.tm.md:3") == 1, "err=" .. err)

    -- Same-file move with --before also warns only once per file
    out, err, code = run_split('add "Second task"')
    out, err, code = run_split('move "Second task" --before "Planned task"')
    check("indented-warn", "same-file move with --before warns once per file",
        code == 0 and count_substr(err, "active.tm.md:3") == 1, "err=" .. err)

    cleanup_dir(tmp)
end

-- ── tm payload ───────────────────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local active, future = tmp .. "/.tasks/active.tm.md", tmp .. "/.tasks/future.tm.md"
    tmio.mkdir_p(tmp .. "/.tasks")
    local DOC = "# Current Sprint\n\n" ..
        "- [ ] First task id:aaaaa\n" ..
        "    > **Context:** Why it matters.\n\n" ..
        "    Existing note.\n\n" ..
        "- [ ] Second task id:bbbbb\n\n" ..
        "- [x] Third task id:ccccc\n" ..
        "    > **Completed:** 2026-11-01\n"
    local function reset()
        write(active, DOC)
        write(future, "# Planned Work\n\n- [ ] Planned task id:ddddd\n")
    end
    local function valid(path) return #tmval.validate_lines(tmscan.lines_of(read(path))) == 0 end
    -- Run `tm payload ARGS` with `input` on stdin.
    local function payload(args, input)
        write(tmp .. "/stdin.txt", input or "")
        return tm_in(tmp, "payload " .. args .. " < stdin.txt")
    end
    local out, code

    reset()
    out, code = tm_in(tmp, "payload aaaaa < /dev/null")
    check("payload", "prints the payload without its indent",
        code == 0 and out == "> **Context:** Why it matters.\n\nExisting note.\n", out)
    check("payload", "printing changes nothing", read(active) == DOC)
    out, code = tm_in(tmp, "payload bbbbb < /dev/null")
    check("payload", "prints nothing for a task without a payload", code == 0 and out == "", out)

    out, code = payload("bbbbb --append", "A finding.\n\n```\n\tcode  \n```\n")
    check("payload", "--append gives a task its first payload",
        code == 0 and read(active):find("- [ ] Second task id:bbbbb\n    A finding.\n\n    ```\n    \tcode  \n    ```\n\n- [x] Third", 1, true) ~= nil,
        out .. read(active))
    check("payload", "--append reports the task", out:find("Appended: [bbbbb] Second task", 1, true) ~= nil, out)

    out, code = payload("aaaaa --append", "\nReview: looks right.\n\n")
    check("payload", "--append adds after the existing payload, separated by one blank line",
        code == 0 and read(active):find("    Existing note.\n\n    Review: looks right.\n\n- [ ] Second", 1, true) ~= nil,
        out .. read(active))
    check("payload", "file validates after --append", valid(active))

    out, code = payload("aaaaa --replace", "> **Context:** Rewritten.\n\nNew body.\n")
    check("payload", "--replace swaps the whole payload and leaves the task line",
        code == 0 and read(active):find("- [ ] First task id:aaaaa\n    > **Context:** Rewritten.\n\n    New body.\n\n- [ ] Second", 1, true) ~= nil
            and read(active):find("Existing note", 1, true) == nil, out .. read(active))
    check("payload", "--replace reports the task", out:find("Replaced: [aaaaa] First task", 1, true) ~= nil, out)
    check("payload", "file validates after --replace", valid(active))

    reset()
    out, code = tm_in(tmp, "payload aaaaa < /dev/null > round.txt && lua " .. tm_abs .. " payload aaaaa --replace < round.txt")
    check("payload", "print piped back into --replace leaves the file unchanged", code == 0 and read(active) == DOC, read(active))

    out, code = payload("ccccc --append", "Reviewed after the fact.\n")
    check("payload", "a completed task takes a note too",
        code == 0 and read(active):find("    > **Completed:** 2026-11-01\n\n    Reviewed after the fact.\n", 1, true) ~= nil, out .. read(active))

    out, code = payload("ddddd --append", "Planning note.\n")
    check("payload", "a task only in future.tm.md is found there",
        code == 0 and read(future):find("- [ ] Planned task id:ddddd\n    Planning note.\n", 1, true) ~= nil, out)
    out, code = payload("ddddd --append --file .tasks/active.tm.md", "Nope.\n")
    check("payload", "--file searches only that file", code ~= 0 and out:find("No task found", 1, true) ~= nil, out)

    -- Refusals: nothing is written.
    reset()
    for _, case in ipairs({
        { "a task token (V9)", "- [ ] nested\n", "V9" },
        { "a bare quote line (V10)", "> just a reminder\n", "V10" },
        { "an unclosed fence (V12)", "```\ncode\n", "V12" },
    }) do
        out, code = payload("aaaaa --append", case[2])
        check("payload", "refuses " .. case[1] .. " and writes nothing",
            code ~= 0 and out:find(case[3], 1, true) ~= nil and read(active) == DOC, out)
    end
    out, code = payload("aaaaa --replace", "> **Context:** x\nfreeform directly beneath\n")
    check("payload", "refusal names the offending stdin line",
        code ~= 0 and out:find("stdin:2", 1, true) ~= nil and out:find("V11", 1, true) ~= nil and read(active) == DOC, out)
    out, code = payload("aaaaa --replace", "\n  \n")
    check("payload", "refuses empty input rather than erase a payload",
        code ~= 0 and out:find("empty", 1, true) ~= nil and read(active) == DOC, out)
    out, code = payload("aaaaa --append --replace", "x\n")
    check("payload", "refuses --append with --replace", code ~= 0 and read(active) == DOC, out)
    out, code = payload("'no such task' --append", "x\n")
    check("payload", "reports an unknown task", code ~= 0 and out:find("No task found", 1, true) ~= nil, out)
    out, code = payload("aaaaa --append --tasks-dir nowhere", "x\n")
    check("payload", "reports a missing tasks directory", code ~= 0 and out:find("directory does not exist: nowhere", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "payload aaaaa --file .tasks/missing.tm.md < /dev/null")
    check("payload", "reports a missing task file", code ~= 0 and out:find("no such file: .tasks/missing.tm.md", 1, true) ~= nil, out)
    out, code = payload("task --append", "x\n")
    check("payload", "reports an ambiguous pattern with handles",
        code ~= 0 and out:find("Ambiguous", 1, true) ~= nil and out:find("[aaaaa]", 1, true) ~= nil, out)

    -- CRLF documents keep their line endings.
    write(active, (DOC:gsub("\n", "\r\n")))
    out, code = payload("bbbbb --append", "Note.\n")
    check("payload", "keeps CRLF line endings",
        code == 0 and read(active):find("id:bbbbb\r\n    Note.\r\n", 1, true) ~= nil
            and read(active):gsub("\r\n", ""):find("[\r\n]") == nil, out)

    -- Concurrent appends from separate processes all land.
    reset()
    local jobs = {}
    for i = 1, 6 do
        jobs[#jobs + 1] = string.format("(printf 'Note %d.\\n' | lua %s payload %s --append) &", i, tm_abs, i % 2 == 0 and "aaaaa" or "bbbbb")
    end
    io.popen(string.format("cd %s && ( %s wait ) 2>&1", tmio.shell_quote(tmp), table.concat(jobs, " "))):read("*a")
    local body, landed = read(active), 0
    for i = 1, 6 do
        if body:find("    Note " .. i .. ".\n", 1, true) then landed = landed + 1 end
    end
    check("payload", "six concurrent --append runs all land", landed == 6, body)
    check("payload", "file validates after concurrent --append", valid(active))

    cleanup_dir(tmp)
end

-- ── tm claim and tm release ──────────────────────────────────────────────

do
    local tmp = make_temp_dir()
    local active = tmp .. "/.tasks/active.tm.md"
    local future = tmp .. "/.tasks/future.tm.md"
    local completed = tmp .. "/.tasks/completed.tm.md"
    local today = os.date("%Y-%m-%d")
    local function valid(p) return #tmval.validate_lines(tmscan.lines_of(read(p))) == 0 end

    local function tm_in(dir, cmd, env_prefix)
        local p = io.popen(string.format("cd %s && %s lua %s %s 2>&1; echo __CODE__$?",
            tmio.shell_quote(dir), env_prefix or "", tmio.shell_quote(tm_abs), cmd))
        local out = p:read("*a")
        p:close()
        local code = tonumber(out:match("__CODE__(%d+)%s*$"))
        return out:gsub("__CODE__%d+%s*$", ""), code
    end

    local DOC = table.concat({
        "# Current Sprint",
        "",
        "- [ ] No payload task id:aaaaa",
        "- [ ] Field run task id:bbbbb",
        "    > **Context:** Existing context.",
        "",
        "- [ ] Freeform only task id:ccccc",
        "    Some freeform note.",
        "",
        "- [ ] Fenced claim task id:ddddd",
        "    ```markdown",
        "    > **Claimed:** 2026-01-01 example",
        "    ```",
        "",
        "- [x] Completed task id:eeeee",
        "    > **Completed:** 2026-11-01",
        "",
    }, "\n")

    local function reset()
        tmio.mkdir_p(tmp .. "/.tasks")
        write(active, DOC)
        write(future, "# Planned Work\n")
        write(completed, "# Completed Archive\n")
    end

    reset()

    -- 1. Claim on all three payload shapes (outside git -> date alone)
    local out, code = tm_in(tmp, "claim aaaaa", "TM_CLAIMANT=")
    check("claim", "claim on task with no payload succeeds",
        code == 0 and out:find("Claimed: [aaaaa] No payload task id:aaaaa", 1, true) ~= nil, out)
    check("claim", "stamps date alone outside git",
        read(active):find("- [ ] No payload task id:aaaaa\n    > **Claimed:** " .. today .. "\n", 1, true) ~= nil, read(active))
    check("claim", "validates after claim on no-payload task", valid(active))

    out, code = tm_in(tmp, "claim bbbbb --as worker-1")
    check("claim", "claim on task with field run succeeds", code == 0, out)
    check("claim", "joins leading field run after existing fields",
        read(active):find("    > **Context:** Existing context.\n    > **Claimed:** " .. today .. " worker-1\n", 1, true) ~= nil, read(active))
    check("claim", "validates after claim on field-run task", valid(active))

    out, code = tm_in(tmp, "claim ccccc", "TM_CLAIMANT=env-agent")
    check("claim", "claim on task with freeform content only succeeds (TM_CLAIMANT)", code == 0, out)
    check("claim", "inserts blank line before freeform content (V11)",
        read(active):find("- [ ] Freeform only task id:ccccc\n    > **Claimed:** " .. today .. " env-agent\n\n    Some freeform note.", 1, true) ~= nil, read(active))
    check("claim", "validates after claim on freeform-only task", valid(active))

    -- 2. Second claim refused and file byte-identical; --force replaces in place
    local before_refuse = read(active)
    out, code = tm_in(tmp, "claim bbbbb --as worker-2")
    check("claim", "second claim is refused with exit 1",
        code ~= 0 and out:find("already claimed", 1, true) ~= nil and out:find(today .. " worker-1", 1, true) ~= nil, out)
    check("claim", "refused second claim leaves file byte-identical", read(active) == before_refuse)

    out, code = tm_in(tmp, "claim bbbbb --as worker-2 --force")
    check("claim", "--force replaces existing Claimed field in place",
        code == 0 and read(active):find("    > **Claimed:** " .. today .. " worker-2\n", 1, true) ~= nil
            and not read(active):find("worker-1", 1, true), read(active))
    check("claim", "validates after --force", valid(active))

    -- 3. Release restores file byte-for-byte in all three payload shapes
    out, code = tm_in(tmp, "release aaaaa")
    check("release", "release on no-payload task succeeds",
        code == 0 and out:find("Released: [aaaaa] No payload task id:aaaaa", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "release bbbbb")
    check("release", "release on field-run task succeeds", code == 0, out)
    out, code = tm_in(tmp, "release ccccc")
    check("release", "release on freeform-only task succeeds", code == 0, out)
    check("release", "releasing all three restores file byte-for-byte", read(active) == DOC, read(active))

    -- 4. Release of unclaimed task exits 1
    out, code = tm_in(tmp, "release aaaaa")
    check("release", "release on unclaimed task exits 1",
        code ~= 0 and out:find("not claimed", 1, true) ~= nil, out)

    -- 5. Fenced Claimed line is not a claim
    out, code = tm_in(tmp, "release ddddd")
    check("claim", "fenced Claimed line is not treated as a claim by release", code ~= 0, out)
    out, code = tm_in(tmp, "claim ddddd --as real")
    check("claim", "can claim task whose payload has fenced Claimed example", code == 0, out)

    -- 6. Completed task refused, bad claimant refused
    out, code = tm_in(tmp, "claim eeeee --as x")
    check("claim", "refuses completed task", code ~= 0 and out:find("already completed", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "claim aaaaa --as 'bad **Key:** val'")
    check("claim", "refuses claimant containing **Key:**", code ~= 0, out)
    out, code = tm_in(tmp, "claim aaaaa --as 'line1\nline2'")
    check("claim", "refuses claimant containing newline", code ~= 0, out)

    -- 7. Git branch fallback for claimant
    if HAVE_GIT then
        local gtmp = make_temp_dir()
        tmio.mkdir_p(gtmp .. "/.tasks")
        write(gtmp .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] Git task id:ggggg\n")
        io.popen(string.format("git -C %s init -q -b stream/s1 && git -C %s config user.name t && git -C %s config user.email t@e",
            tmio.shell_quote(gtmp), tmio.shell_quote(gtmp), tmio.shell_quote(gtmp))):close()
        out, code = tm_in(gtmp, "claim ggggg", "TM_CLAIMANT=")
        check("claim", "uses current git branch when --as and TM_CLAIMANT are unset",
            code == 0 and read(gtmp .. "/.tasks/active.tm.md"):find("> **Claimed:** " .. today .. " stream/s1", 1, true) ~= nil,
            out .. "\n" .. read(gtmp .. "/.tasks/active.tm.md"))
        cleanup_dir(gtmp)
    end

    -- 8. Six concurrent tm claim runs on one task give exactly one success
    reset()
    local jobs = {}
    for i = 1, 6 do
        jobs[#jobs + 1] = string.format("(lua %s claim aaaaa --as w%d > out%d.txt 2>&1; echo $? > rc%d.txt) &",
            tm_abs, i, i, i)
    end
    io.popen(string.format("cd %s && ( %s wait )", tmio.shell_quote(tmp), table.concat(jobs, " "))):read("*a")
    local successes = 0
    for i = 1, 6 do
        local rc = tonumber(read(tmp .. "/rc" .. i .. ".txt"))
        if rc == 0 then successes = successes + 1 end
    end
    check("claim", "six concurrent tm claim runs on one task give exactly one success", successes == 1, "successes=" .. successes)
    check("claim", "file validates after concurrent claims", valid(active))

    cleanup_dir(tmp)
end

-- ── tm next with claims and --claim ──────────────────────────────────────

do
    local tmp = make_temp_dir()
    local active = tmp .. "/.tasks/active.tm.md"
    local future = tmp .. "/.tasks/future.tm.md"
    local completed = tmp .. "/.tasks/completed.tm.md"
    local today = os.date("%Y-%m-%d")
    local function valid(p) return #tmval.validate_lines(tmscan.lines_of(read(p))) == 0 end

    local function tm_in(dir, cmd, env_prefix)
        local p = io.popen(string.format("cd %s && %s lua %s %s 2>&1; echo __CODE__$?",
            tmio.shell_quote(dir), env_prefix or "", tmio.shell_quote(tm_abs), cmd))
        local out = p:read("*a")
        p:close()
        local code = tonumber(out:match("__CODE__(%d+)%s*$"))
        return out:gsub("__CODE__%d+%s*$", ""), code
    end

    local function reset(body)
        tmio.mkdir_p(tmp .. "/.tasks")
        write(active, body)
        write(future, "# Planned Work\n")
        write(completed, "# Completed Archive\n")
    end

    -- 1. Skips claimed first task and claimed (A) task; claimed dependency still blocks
    reset(table.concat({
        "# Current Sprint",
        "",
        "- [ ] (A) Claimed high priority id:aaaaa",
        "    > **Claimed:** 2026-11-16 other",
        "",
        "- [ ] Claimed first id:bbbbb",
        "    > **Claimed:** 2026-11-16 other",
        "",
        "- [ ] Blocked by claimed id:ccccc",
        "    > **Depends:** id:aaaaa",
        "",
        "- [ ] Ready task id:ddddd",
        "",
    }, "\n"))
    local out, code = tm_in(tmp, "next")
    check("next-claim", "skips claimed (A), claimed first, and task depending on claimed task",
        code == 0 and out:find("[ddddd] Ready task", 1, true) ~= nil, out)

    -- 2. Sequential tm next --claim returns two different tasks
    reset(table.concat({
        "# Current Sprint",
        "",
        "- [ ] First task id:aaaaa",
        "- [ ] Second task id:bbbbb",
        "",
    }, "\n"))
    out, code = tm_in(tmp, "next --claim --as s1")
    check("next-claim", "first next --claim returns first task",
        code == 0 and out:find("[aaaaa] First task", 1, true) ~= nil, out)
    local out2, code2 = tm_in(tmp, "next --claim --as s2")
    check("next-claim", "second next --claim returns second task",
        code2 == 0 and out2:find("[bbbbb] Second task", 1, true) ~= nil, out2)

    -- 3. When everything left is claimed, stderr notes how many and points to tm list
    local out3, code3 = tm_in(tmp, "next")
    check("next-claim", "when all tasks are claimed, exits 0 and stderr notes claimed count and tm list",
        code3 == 0 and out3:find("no task is ready", 1, true) ~= nil
            and out3:find("2 claimed", 1, true) ~= nil
            and out3:find("tm list", 1, true) ~= nil, out3)

    -- 4. tm next after tm release returns the task again
    local _, rel_code = tm_in(tmp, "release aaaaa")
    check("next-claim", "release succeeds", rel_code == 0)
    out, code = tm_in(tmp, "next")
    check("next-claim", "tm next after tm release returns the released task",
        code == 0 and out:find("[aaaaa] First task", 1, true) ~= nil, out)

    -- 5. N concurrent tm next --claim runs over N ready tasks
    reset(table.concat({
        "# Current Sprint",
        "",
        "- [ ] Task 1 id:t0001",
        "- [ ] Task 2 id:t0002",
        "- [ ] Task 3 id:t0003",
        "- [ ] Task 4 id:t0004",
        "",
    }, "\n"))
    local jobs = {}
    for i = 1, 4 do
        jobs[#jobs + 1] = string.format("(lua %s next --claim --as w%d > out%d.txt 2> err%d.txt; echo $? > rc%d.txt) &",
            tm_abs, i, i, i, i)
    end
    io.popen(string.format("cd %s && ( %s wait )", tmio.shell_quote(tmp), table.concat(jobs, " "))):read("*a")
    local seen = {}
    local distinct = 0
    for i = 1, 4 do
        local line = read(tmp .. "/out" .. i .. ".txt"):match("^%[(%S+)%]")
        if line and not seen[line] then
            seen[line] = true
            distinct = distinct + 1
        end
    end
    check("next-claim", "4 concurrent next --claim runs print 4 distinct handles", distinct == 4, "distinct=" .. distinct)
    check("next-claim", "file validates after concurrent next --claim", valid(active))

    -- 6. One ready task and several concurrent runs -> exactly one prints a task
    reset("# Current Sprint\n\n- [ ] Only task id:only1\n")
    jobs = {}
    for i = 1, 4 do
        jobs[#jobs + 1] = string.format("(lua %s next --claim --as w%d > one_out%d.txt 2> one_err%d.txt) &",
            tm_abs, i, i, i)
    end
    io.popen(string.format("cd %s && ( %s wait )", tmio.shell_quote(tmp), table.concat(jobs, " "))):read("*a")
    local printed = 0
    for i = 1, 4 do
        if read(tmp .. "/one_out" .. i .. ".txt"):find("[only1]", 1, true) then printed = printed + 1 end
    end
    check("next-claim", "with 1 ready task and 4 concurrent runs, exactly 1 prints a task", printed == 1, "printed=" .. printed)

    -- 7. --claim refused on non-next commands, --as refused on non-next/non-claim commands
    out, code = tm_in(tmp, "list --claim")
    check("next-claim", "--claim refused on list", code ~= 0 and out:find("Usage: tm list", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "list --as foo")
    check("next-claim", "--as refused on list", code ~= 0 and out:find("Usage: tm list", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "next --as foo")
    check("next-claim", "--as without --claim refused on next", code ~= 0 and out:find("Usage: tm next", 1, true) ~= nil, out)

    -- 8. Multiple Depends fields: second Depends still blocks
    reset(table.concat({
        "# Current Sprint",
        "",
        "- [x] Done dep id:aaaaa",
        "    > **Completed:** 2026-11-10",
        "",
        "- [ ] Blocked by second Depends id:ccccc",
        "    > **Depends:** id:aaaaa",
        "    > **Notes:** middle",
        "    > **Depends:** id:bbbbb",
        "",
        "- [ ] Pending dep id:bbbbb",
        "",
    }, "\n"))
    out, code = tm_in(tmp, "next")
    check("next-claim", "second Depends field still blocks task",
        code == 0 and out:find("[bbbbb] Pending dep", 1, true) ~= nil, out)

    -- 9. Duplicate Claimed fields: release and done remove all of them
    reset(table.concat({
        "# Current Sprint",
        "",
        "- [ ] Double claimed release id:aaaaa",
        "    > **Claimed:** 2026-11-16 s1",
        "    > **Notes:** keep me",
        "    > **Claimed:** 2026-11-16 s2",
        "",
        "- [ ] Double claimed done id:bbbbb",
        "    > **Claimed:** 2026-11-16 s1",
        "    > **Claimed:** 2026-11-16 s2",
        "",
    }, "\n"))
    out, code = tm_in(tmp, "release aaaaa")
    local after_rel = read(active):match("Double claimed release.-Double claimed done") or ""
    check("release", "release removes all Claimed fields when duplicated",
        code == 0 and not after_rel:find("**Claimed:**", 1, true)
            and after_rel:find("> **Notes:** keep me", 1, true) ~= nil, read(active))
    out, code = tm_in(tmp, "done bbbbb")
    check("done-claim", "done removes all Claimed fields when duplicated",
        code == 0 and not read(active):find("**Claimed:**", 1, true), read(active))

    cleanup_dir(tmp)
end

-- ── tm done clears claim; tm list shows/filters claims ───────────────────

do
    local tmp = make_temp_dir()
    local active = tmp .. "/.tasks/active.tm.md"
    local future = tmp .. "/.tasks/future.tm.md"
    local completed = tmp .. "/.tasks/completed.tm.md"
    local function valid(p) return #tmval.validate_lines(tmscan.lines_of(read(p))) == 0 end

    local function tm_in(dir, cmd)
        local p = io.popen(string.format("cd %s && lua %s %s 2>&1; echo __CODE__$?",
            tmio.shell_quote(dir), tmio.shell_quote(tm_abs), cmd))
        local out = p:read("*a")
        p:close()
        local code = tonumber(out:match("__CODE__(%d+)%s*$"))
        return out:gsub("__CODE__%d+%s*$", ""), code
    end

    tmio.mkdir_p(tmp .. "/.tasks")
    write(active, table.concat({
        "# Current Sprint",
        "",
        "- [ ] +api Only claim id:aaaaa",
        "    > **Claimed:** 2026-11-16 s1",
        "",
        "- [ ] +cli Claim in field run id:bbbbb",
        "    > **Context:** Context line.",
        "    > **Claimed:** 2026-11-16 s2",
        "",
        "- [ ] +api Claim before freeform id:ccccc",
        "    > **Claimed:** 2026-11-16 s3",
        "",
        "    Freeform body.",
        "",
        "- [ ] +api Unclaimed task id:ddddd",
        "",
        "- [x] Done with leftover claim id:eeeee",
        "    > **Completed:** 2026-11-10",
        "    > **Claimed:** 2026-11-09 old",
        "",
    }, "\n"))
    write(future, "# Planned Work\n\n- [ ] Future claimed id:fffff\n    > **Claimed:** 2026-11-16 s4\n")
    write(completed, "# Completed Archive\n")

    -- 1. tm list shows (claimed: VALUE) for pending claimed tasks, leaves unclaimed unchanged, hides done's Claimed
    local out, code = tm_in(tmp, "list")
    check("list-claim", "default list appends (claimed: VALUE) to claimed pending tasks",
        code == 0 and out:find("[aaaaa] +api Only claim id:aaaaa (claimed: 2026-11-16 s1)", 1, true) ~= nil, out)
    check("list-claim", "default list leaves unclaimed task line unchanged",
        out:find("[ddddd] +api Unclaimed task id:ddddd\n", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "list --all")
    check("list-claim", "--all shows (claimed: VALUE) on pending and hides leftover Claimed on done",
        code == 0
            and out:find("[aaaaa] [ ] +api Only claim id:aaaaa (claimed: 2026-11-16 s1)", 1, true) ~= nil
            and out:find("[ddddd] [ ] +api Unclaimed task id:ddddd\n", 1, true) ~= nil
            and out:find("[eeeee] [x] Done with leftover claim id:eeeee\n", 1, true) ~= nil, out)

    -- 2. --claimed and --unclaimed, combined with tags, and refused on other commands
    out, code = tm_in(tmp, "list --claimed +api")
    check("list-claim", "--claimed +api lists only claimed +api tasks",
        code == 0
            and out:find("[aaaaa]", 1, true) ~= nil
            and out:find("[ccccc]", 1, true) ~= nil
            and not out:find("[bbbbb]", 1, true)
            and not out:find("[ddddd]", 1, true)
            and not out:find("[eeeee]", 1, true), out)

    out, code = tm_in(tmp, "list --unclaimed +api")
    check("list-claim", "--unclaimed +api lists only unclaimed +api tasks",
        code == 0
            and out:find("[ddddd]", 1, true) ~= nil
            and not out:find("[aaaaa]", 1, true)
            and not out:find("[eeeee]", 1, true), out)

    out, code = tm_in(tmp, "next --claimed")
    check("list-claim", "--claimed refused on next", code ~= 0 and out:find("Usage: tm next", 1, true) ~= nil, out)
    out, code = tm_in(tmp, "next --unclaimed")
    check("list-claim", "--unclaimed refused on next", code ~= 0 and out:find("Usage: tm next", 1, true) ~= nil, out)

    -- 3. tm done clears Claimed in all three payload shapes
    for _, id in ipairs({ "aaaaa", "bbbbb", "ccccc" }) do
        out, code = tm_in(tmp, "done " .. id)
        check("done-claim", "done " .. id .. " succeeds", code == 0, out)
    end
    local body = read(active)
    check("done-claim", "Claimed is removed from all three completed tasks",
        not body:find("2026-11-16 s1", 1, true)
            and not body:find("2026-11-16 s2", 1, true)
            and not body:find("2026-11-16 s3", 1, true), body)
    check("done-claim", "Context and Freeform body are preserved",
        body:find("> **Context:** Context line.", 1, true) ~= nil
            and body:find("    Freeform body.", 1, true) ~= nil, body)
    check("done-claim", "active.tm.md validates after done on claimed tasks", valid(active))

    -- 4. tm move keeps Claimed; tm sweep carries completed task's payload unchanged
    out, code = tm_in(tmp, "move fffff")
    check("move-claim", "move from future to active keeps Claimed field",
        code == 0 and read(active):find("Future claimed id:fffff\n    > **Claimed:** 2026-11-16 s4", 1, true) ~= nil, read(active))

    out, code = tm_in(tmp, "sweep")
    check("sweep-claim", "sweep carries completed task payload unchanged",
        code == 0 and read(completed):find("    Freeform body.", 1, true) ~= nil, read(completed))

    cleanup_dir(tmp)
end

-- ── 23. tm tree ─────────────────────────────────────────────────────────────

do
    local lines = tmscan.lines_of([[
# Sprint

- [ ] +claim @spec Specify claiming id:t1ewr

- [ ] +claim @lua Implement claim id:vb6g7
    > **Depends:** id:t1ewr

- [ ] +claim @lua Update next id:hs2tw
    > **Depends:** id:vb6g7

- [ ] +claim @lua Update done id:7k6tn
    > **Depends:** id:vb6g7

- [ ] +claim @lua Parallel test id:gj3qb
    > **Depends:** id:hs2tw id:7k6tn

- [ ] Independent task id:430s6
    > **Claimed:** 2026-11-16 s1

- [x] Already done id:done1

- [ ] Depends on done id:aftr1
    > **Depends:** id:done1
]])

    local tree = tmmutate.format_tree(lines)
    local joined = table.concat(tree, "\n")
    check("tree-unit", "handles have no brackets",
        joined:find("t1ewr (ready)", 1, true) ~= nil
            and joined:find("[t1ewr]", 1, true) == nil, joined)
    check("tree-unit", "diamond shows also needs on first and see above on second",
        joined:find("gj3qb (also needs: id:7k6tn)", 1, true) ~= nil
            and joined:find("gj3qb (see above)", 1, true) ~= nil, joined)
    check("tree-unit", "claimed root shows claimed value instead of ready",
        joined:find("430s6 (claimed: 2026-11-16 s1)", 1, true) ~= nil, joined)
    check("tree-unit", "task depending on done task is a ready root",
        joined:find("aftr1 (ready)", 1, true) ~= nil
            and joined:find("done1", 1, true) == nil, joined)
    check("tree-unit", "independent chains separated by blank line",
        joined:find("\n\n430s6 (claimed:", 1, true) ~= nil, joined)

    local ascii_tree = tmmutate.format_tree(lines, { ascii = true })
    local ascii_joined = table.concat(ascii_tree, "\n")
    local expected_ascii = table.concat({
        "t1ewr (ready) +claim @spec Specify claiming id:t1ewr",
        "`-- vb6g7 +claim @lua Implement claim id:vb6g7",
        "    |-- hs2tw +claim @lua Update next id:hs2tw",
        "    |   `-- gj3qb (also needs: id:7k6tn) +claim @lua Parallel test id:gj3qb",
        "    `-- 7k6tn +claim @lua Update done id:7k6tn",
        "        `-- gj3qb (see above) +claim @lua Parallel test id:gj3qb",
        "",
        "430s6 (claimed: 2026-11-16 s1) Independent task id:430s6",
        "",
        "aftr1 (ready) Depends on done id:aftr1",
    }, "\n")
    check("tree-unit", "exact ascii diamond tree output",
        ascii_joined == expected_ascii, ascii_joined)

    local all_tree = tmmutate.format_tree(lines, { filter = "all" })
    local all_joined = table.concat(all_tree, "\n")
    check("tree-unit", "--all includes completed task and links dependant under it",
        all_joined:find("done1 [x]", 1, true) ~= nil
            and all_joined:find("aftr1 (ready)", 1, true) ~= nil, all_joined)

    -- Self-dependency, cycle root, ancestor exclusion, and unknown dependency
    local cycle_lines = tmscan.lines_of([[
- [ ] Self dep id:self1
    > **Depends:** id:self1

- [ ] Task A id:aaaa1
    > **Depends:** id:cccc3

- [ ] Task B id:bbbb2
    > **Depends:** id:aaaa1

- [ ] Task C id:cccc3
    > **Depends:** id:bbbb2 id:aaaa1

- [ ] Task D id:dddd4
    > **Depends:** id:zzzzz
]])
    local ctree = table.concat(tmmutate.format_tree(cycle_lines), "\n")
    check("tree-unit", "self-dependency is flagged (cycle!) and not ready",
        ctree:find("self1 (cycle!) Self dep id:self1", 1, true) ~= nil, ctree)
    check("tree-unit", "top of cycle shows its unmet blocker",
        ctree:find("aaaa1 (needs: id:cccc3) Task A id:aaaa1", 1, true) ~= nil, ctree)
    check("tree-unit", "cycle terminates and marks (cycle!)",
        ctree:find("aaaa1 (cycle!)", 1, true) ~= nil, ctree)
    check("tree-unit", "also needs excludes ancestors on the active path",
        ctree:find("cccc3 (also needs:", 1, true) == nil, ctree)
    check("tree-unit", "unknown dependency is marked inline",
        ctree:find("dddd4 (unknown: id:zzzzz)", 1, true) ~= nil, ctree)
end

do
    local tmp = make_temp_dir()
    tmio.mkdir_p(tmp .. "/.tasks")
    local active = tmp .. "/.tasks/active.tm.md"
    local future = tmp .. "/.tasks/future.tm.md"
    local completed = tmp .. "/.tasks/completed.tm.md"

    write(active, [[
# Active

- [ ] +api Root one id:rrrr1

- [ ] +api Child one id:cccc1
    > **Depends:** id:rrrr1

- [ ] +ui Blocked by future id:bbbb1
    > **Depends:** id:ffff1

- [ ] +api Unblocked by completed id:dddd1
    > **Depends:** id:eeee1
]])
    write(future, [[
# Future

- [ ] Future blocker id:ffff1
]])
    write(completed, [[
# Completed

- [x] Done blocker id:eeee1
    > **Completed:** 2026-11-15
]])

    local out, code = tm_in(tmp, "tree")
    check("tree-cli", "tm tree exits 0", code == 0, out)
    check("tree-cli", "tm tree resolves completed cross-file dep as ready",
        out:find("dddd1 (ready)", 1, true) ~= nil, out)
    check("tree-cli", "tm tree flags pending future cross-file dep",
        out:find("bbbb1 (needs: id:ffff1 [future])", 1, true) ~= nil, out)
    check("tree-cli", "tm tree prints summary for task blocked behind future dep",
        out:find("1 task is blocked behind id:ffff1 (pending in future.tm.md)", 1, true) ~= nil, out)
    check("tree-cli", "tm tree links in-file parent to child",
        out:find("rrrr1 (ready)", 1, true) ~= nil
            and out:find("cccc1 +api Child one", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree +api")
    check("tree-cli", "tm tree +api filters by tag",
        code == 0 and out:find("rrrr1", 1, true) ~= nil and out:find("bbbb1", 1, true) == nil, out)

    out, code = tm_in(tmp, "tree --not +ui")
    check("tree-cli", "tm tree --not +ui excludes tag",
        code == 0 and out:find("rrrr1", 1, true) ~= nil and out:find("bbbb1", 1, true) == nil, out)

    out, code = tm_in(tmp, "tree --help")
    check("tree-cli", "tm tree --help exits 0", code == 0 and out:find("Usage: tm tree", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "list --ascii")
    check("tree-cli", "--ascii refused on list", code ~= 0 and out:find("Usage: tm list", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --claimed")
    check("tree-cli", "--claimed refused on tree", code ~= 0 and out:find("Usage: tm tree", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree .tasks/active.tm.md .tasks/future.tm.md")
    check("tree-cli", "multiple files print == file headers",
        code == 0
            and out:find("== .tasks/active.tm.md", 1, true) ~= nil
            and out:find("== .tasks/future.tm.md", 1, true) ~= nil
            and out:find("ffff1 (ready) Future blocker id:ffff1", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why bbbb1")
    check("tree-cli", "tm tree --why shows direct dep source line",
        code == 0 and out:find("id:ffff1", 1, true) ~= nil
            and out:find("pending in future.tm.md", 1, true) ~= nil
            and out:find("line 9", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why nonexistent")
    check("tree-cli", "tm tree --why unknown id exits non-zero", code ~= 0, out)

    -- Transitive stall + continuation-line provenance
    write(active, [[
# Active

- [ ] +api Root one id:rrrr1

- [ ] +ui Blocked by future via continuation id:bbbb1
    > **Depends:** id:rrrr1
    > **Routed by:** id:ffff1

- [ ] +ui Downstream one id:bbbb2
    > **Depends:** id:bbbb1

- [ ] +ui Downstream two id:bbbb3
    > **Depends:** id:bbbb2
]])
    out, code = tm_in(tmp, "tree")
    check("tree-cli", "tm tree summarizes transitive count behind future dep",
        code == 0 and out:find("3 tasks are blocked behind id:ffff1 (pending in future.tm.md)", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why id:bbbb1")
    check("tree-cli", "tm tree --why flags continuation-line dependency provenance",
        code == 0 and out:find("id:ffff1", 1, true) ~= nil
            and out:find("continuation of Depends at line 6", 1, true) ~= nil
            and out:find("line 7", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why rrrr1")
    check("tree-cli", "tm tree --why reports (no dependencies) for root task",
        code == 0 and out:find("(no dependencies)", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "list --why rrrr1")
    check("tree-cli", "--why refused on list",
        code ~= 0 and out:find("Usage: tm list", 1, true) ~= nil, out)

    -- Diamond downstream behind future dep + id inside bold key provenance
    write(active, [[
# Active

- [ ] Left id:llll1
    > **Depends:** id:ffff1

- [ ] Right id:rrrr2
    > **Depends:** id:ffff1

- [ ] Join id:jjjj1
    > **Depends:** id:llll1, id:rrrr2
    > **Depends changed (2026-11-15, the check-in id:n177h):** note
]])
    out, code = tm_in(tmp, "tree")
    check("tree-cli", "tm tree counts diamond downstream tasks once in future summary",
        code == 0 and out:find("3 tasks are blocked behind id:ffff1 (pending in future.tm.md)", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why jjjj1")
    check("tree-cli", "tm tree --why shows id inside bold continuation key",
        code == 0 and out:find("id:n177h (unknown) <- line 11 (continuation of Depends at line 10)", 1, true) ~= nil, out)

    -- A completed dependant is not blocked: --all must not count it
    write(active, [[
# Active

- [ ] Blocked id:bbbb1
    > **Depends:** id:ffff1

- [ ] Pending child id:bbbb2
    > **Depends:** id:bbbb1

- [x] Done child id:bbbb3
    > **Depends:** id:bbbb1
    > **Completed:** 2026-11-15
]])
    out, code = tm_in(tmp, "tree --all")
    check("tree-cli", "tm tree --all does not count completed dependants as blocked",
        code == 0 and out:find("2 tasks are blocked behind id:ffff1", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "next")
    check("tree-cli", "tm next names the future.tm.md task stalling the queue",
        code == 0 and out:find("no task is ready", 1, true) ~= nil
            and out:find("id:ffff1", 1, true) ~= nil
            and out:find("future.tm.md", 1, true) ~= nil, out)

    out, code = tm_in(tmp, "tree --why ffff1")
    check("tree-cli", "tm tree --why finds a task in another task file",
        code == 0 and out:find("Future blocker id:ffff1", 1, true) ~= nil
            and out:find("(no dependencies)", 1, true) ~= nil, out)

    -- A configured future_file is recognised by name, not a hardcoded one
    os.execute("mv " .. tmio.shell_quote(future) .. " " .. tmio.shell_quote(tmp .. "/.tasks/later.tm.md"))
    write(tmp .. "/.taskmarkrc", "future_file: later.tm.md\n")
    out, code = tm_in(tmp, "tree")
    check("tree-cli", "tm tree honours a configured future_file",
        code == 0 and out:find("(needs: id:ffff1 [future])", 1, true) ~= nil
            and out:find("blocked behind id:ffff1 (pending in later.tm.md)", 1, true) ~= nil, out)
    os.remove(tmp .. "/.taskmarkrc")
    os.execute("mv " .. tmio.shell_quote(tmp .. "/.tasks/later.tm.md") .. " " .. tmio.shell_quote(future))

    cleanup_dir(tmp)
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
