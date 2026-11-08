#!/usr/bin/env lua
-- tests/tmmutate_test.lua — unit and CLI tests for tmmutate.lua
-- (SPEC-TASKMARK-04 AI & CLI ergonomics: atomic task mutations, compact
-- listings, and ephemeral hashes).

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

    -- 1. tm add
    local status = os.execute(string.format("%s add --tasks-dir %s -p A 'First added task' > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir)))
    check("cli", "tm add exits 0", status == 0 or status == true)

    -- 2. tm list
    local p = io.popen(string.format("%s list --tasks-dir %s", tm_cmd, tmio.shell_quote(tasks_dir)))
    local list_out = p:read("*a")
    p:close()
    check("cli", "tm list outputs task handle", list_out:match("^%[%x%x%x%x%] %(A%) First added task") ~= nil)

    local handle = list_out:match("^%[(%x%x%x%x)%]")

    -- 3. tm done <handle> --git
    local d_status = os.execute(string.format("%s done --tasks-dir %s %s --git HEAD > /dev/null", tm_cmd, tmio.shell_quote(tasks_dir), handle))
    check("cli", "tm done exits 0", d_status == 0 or d_status == true)

    local after_done = io.open(active_file):read("*a")
    check("cli", "task marked done in active.tm.md", after_done:match("%- %[x%] %(A%) First added task") ~= nil)
    check("cli", "task has git: SHA", after_done:match("> %*%*Completed:%*%* %d%d%d%d%-%d%d%-%d%d git:%x+") ~= nil)

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
        " && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init")
    local p = io.popen("cd " .. tmio.shell_quote(dir) .. " && git rev-parse --short HEAD")
    local sha = p:read("*l")
    p:close()
    return sha
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

do
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
end

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
        read(active) == "# Current Sprint\n\n- [ ] Top level\n\n## Alpha\n\n- [ ] a\n\n## Beta\n\n- [ ] b\n", read(active))

    out, code = tm_in(tmp, "move Future --to .tasks/actve.tm.md")
    check("move", "missing destination is an error, no file created",
        code ~= 0 and read(tmp .. "/.tasks/actve.tm.md") == nil, out)
    out, code = tm_in(tmp, "add Something --file .tasks/nosuch.tm.md")
    check("add", "missing target file is an error, no file created",
        code ~= 0 and read(tmp .. "/.tasks/nosuch.tm.md") == nil, out)
    out, code = tm_in(tmp, "list .tasks/nosuch.tm.md")
    check("list", "missing file is an error", code ~= 0, out)
    cleanup_dir(tmp)
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
    check("add", "text after -- may start with '-'", code == 0 and read(tmp .. "/.tasks/active.tm.md") == "# S\n\n- [ ] (A) -v flag handling\n", out)
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

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
