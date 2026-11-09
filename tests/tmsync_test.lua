#!/usr/bin/env lua
-- tests/tmsync_test.lua — unit + end-to-end tests for tmsync.lua and `tm sync`
--
-- Self-contained runner (mirroring tests/tminit_test.lua style).


-- Run hermetically: re-exec under an isolated git environment so the
-- developer's global, system, and GIT_CONFIG_COUNT-injected git config
-- (identity, hooks, signing, defaults) can
-- neither break nor be exercised by these tests. Hooks under test are
-- installed per repository via core.hooksPath.
-- Git is optional for building, testing, and installing Taskmark: the
-- cases that need it are skipped, and reported, when it isn't installed.
local function git_available()
    local ok, _, code = os.execute("git --version >/dev/null 2>&1")
    if type(ok) == "number" then return ok == 0 end
    return ok == true and code == 0
end
if not git_available() then
    print("[SKIP] tm sync: git is not installed")
    os.exit(0)
end

if os.getenv("TM_TEST_GIT_ISOLATED") ~= "1" then
    local q = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    local ok, how, code = os.execute(
        "env TM_TEST_GIT_ISOLATED=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 " ..
        "GIT_AUTHOR_NAME=tm-test GIT_AUTHOR_EMAIL=tm-test@example.invalid " ..
        "GIT_COMMITTER_NAME=tm-test GIT_COMMITTER_EMAIL=tm-test@example.invalid " ..
        q(arg[-1] or "lua") .. " " .. q(arg[0]))
    if type(ok) == "number" then os.exit(ok == 0 and 0 or 1) end
    os.exit((ok and code == 0) and 0 or 1)
end

local script_dir = (arg[0] or "./tests/tmsync_test.lua"):match("^(.*)/[^/]+$") or "."
local abs_root = io.popen("cd " .. script_dir .. "/.. && pwd"):read("*l")
local abs_tm = string.format("lua %s/src/tm", abs_root)
package.path = abs_root .. "/src/?.lua;" .. package.path

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

local function run_cmd(cmd_str)
    local handle = io.popen(cmd_str .. " 2>&1; echo __EXIT__$?")
    local output = handle:read("*a")
    handle:close()
    local exit_code = tonumber(output:match("__EXIT__(%d+)")) or -1
    output = output:gsub("__EXIT__%d+%s*$", "")
    return output, exit_code
end

local function run_tm(args_str)
    local tm = script_dir .. "/../src/tm"
    return run_cmd(string.format("lua %s %s", tm, args_str or ""))
end

local function run_tmsync_cli(args_str)
    local tmsync = script_dir .. "/../src/tmsync.lua"
    return run_cmd(string.format("lua %s %s", tmsync, args_str or ""))
end

local function make_temp_dir(prefix)
    local dir = string.format("/tmp/%s_%d_%d", prefix or "tmsync_test", os.time(), math.random(100000, 999999))
    os.execute("mkdir -p " .. dir)
    return dir
end

-- ── 1. Error cases: nonexistent tasks dir or not a git worktree ──────────────

do
    local dir = make_temp_dir("tmsync_not_git")
    local output, exit_code = run_cmd(string.format("cd %s && %s sync --tasks-dir nonexistent_dir", dir, abs_tm))
    check("error_cases", "nonexistent tasks-dir exits 1", exit_code == 1)
    check("error_cases", "nonexistent tasks-dir reports error", output:match("does not exist") ~= nil)

    local tasks_plain = dir .. "/.tasks"
    os.execute("mkdir -p " .. tasks_plain)
    output, exit_code = run_cmd(string.format("cd %s && %s sync --tasks-dir %s", dir, abs_tm, tasks_plain))
    check("error_cases", "non-git tasks-dir exits 1", exit_code == 1)
    check("error_cases", "non-git tasks-dir reports not a worktree or repo", output:match("not a git") ~= nil)

    os.execute("rm -rf " .. dir)
end

-- ── 2. Help flags ────────────────────────────────────────────────────────────

do
    local out_h, code_h = run_tm("sync -h")
    check("help_flags", "tm sync -h exits 0", code_h == 0)
    check("help_flags", "tm sync -h shows usage", out_h:match("Usage:") ~= nil)

    local out_help, code_help = run_tm("sync --help")
    check("help_flags", "tm sync --help exits 0", code_help == 0)
    check("help_flags", "tm sync --help shows usage", out_help:match("Usage:") ~= nil)
end

-- ── 3. Clean working tree and commit on changes ──────────────────────────────

do
    local dir = make_temp_dir("tmsync_flow")
    -- Setup git repo with main branch and orphan tasks worktree
    os.execute(string.format([[
        cd %s && \
        git init -q -b main && \
        git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "init" && \
        git -c core.hooksPath="" worktree add -q --orphan -b tasks .tasks && \
        cd .tasks && \
        echo "/.tm.lock" > .gitignore && \
        echo "# Current Sprint" > active.tm.md && \
        echo "# Planned Work" > future.tm.md && \
        echo "# Completed Archive" > completed.tm.md && \
        git add -A && \
        git -c user.name=test -c user.email=test@example.com -c core.hooksPath="" commit -q -m "initial tasks"
    ]], dir))

    -- Clean sync
    local out_clean, code_clean = run_cmd(string.format("cd %s && %s sync", dir, abs_tm))
    check("sync_flow", "clean working tree exits 0", code_clean == 0)
    check("sync_flow", "clean working tree reports nothing to sync", out_clean:match("Nothing to sync") ~= nil)

    -- Make a change: add a task
    local active_path = dir .. "/.tasks/active.tm.md"
    local active_content = read_file(active_path)
    write_file(active_path, active_content .. "\n- [ ] New pending task\n")

    -- Sync with custom message
    local custom_msg = "tasks: add new pending task"
    local out_sync, code_sync = run_cmd(string.format("cd %s && %s sync -m %q", dir, abs_tm, custom_msg))
    check("sync_flow", "sync with change exits 0", code_sync == 0)
    check("sync_flow", "sync reports synced", out_sync:match("Synced") ~= nil)

    -- Verify commit message and log in .tasks
    local last_msg, _ = run_cmd(string.format("cd %s/.tasks && git log -1 --pretty=%%s", dir))
    last_msg = last_msg:gsub("%s+$", "")
    check("sync_flow", "commit message matches custom -m", last_msg == custom_msg)

    -- Make another change: default commit message
    write_file(active_path, active_content .. "\n- [ ] Another task\n")
    local out_sync_def, code_sync_def = run_cmd(string.format("cd %s && %s sync", dir, abs_tm))
    check("sync_flow", "default message sync exits 0", code_sync_def == 0)
    local def_msg, _ = run_cmd(string.format("cd %s/.tasks && git log -1 --pretty=%%s", dir))
    def_msg = def_msg:gsub("%s+$", "")
    check("sync_flow", "default commit message starts with tasks: sync", def_msg:match("^tasks: sync") ~= nil)

    os.execute("rm -rf " .. dir)
end

-- ── 4. End-to-end task mutation + sync ────────────────────────────────────────

do
    local dir = make_temp_dir("tmsync_mutation")
    os.execute(string.format([[
        cd %s && \
        git init -q -b main && \
        git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "main initial" && \
        git -c core.hooksPath="" worktree add -q --orphan -b tasks .tasks && \
        cd .tasks && \
        echo "/.tm.lock" > .gitignore && \
        echo "# Current Sprint" > active.tm.md && \
        echo "# Planned Work" > future.tm.md && \
        echo "# Completed Archive" > completed.tm.md && \
        git add -A && \
        git -c user.name=test -c user.email=test@example.com -c core.hooksPath="" commit -q -m "initial tasks"
    ]], dir))

    -- Add a task using `tm add`
    local _, add_code = run_cmd(string.format("cd %s && %s add %q", dir, abs_tm, "+core Sample feature"))
    check("mutation_sync", "tm add exits 0", add_code == 0)

    -- Sync the addition
    local out_sync1, sync1_code = run_cmd(string.format("cd %s && %s sync -m %q", dir, abs_tm, "tasks: add sample feature"))
    check("mutation_sync", "tm sync exits 0 after add", sync1_code == 0)

    -- Mark task done with --git HEAD
    local _, done_code = run_cmd(string.format("cd %s && %s done %q --git HEAD", dir, abs_tm, "Sample"))
    check("mutation_sync", "tm done exits 0", done_code == 0)

    -- Sweep to completed
    local _, sweep_code = run_cmd(string.format("cd %s && %s sweep", dir, abs_tm))
    check("mutation_sync", "tm sweep exits 0", sweep_code == 0)

    -- Sync the completion & sweep
    local out_sync2, sync2_code = run_cmd(string.format("cd %s && %s sync -m %q", dir, abs_tm, "tasks: complete and sweep sample feature"))
    check("mutation_sync", "tm sync exits 0 after sweep", sync2_code == 0)

    -- Verify .tasks status is clean and main branch status is clean
    local tasks_status, _ = run_cmd(string.format("cd %s/.tasks && git status --porcelain", dir))
    check("mutation_sync", "tasks worktree status is clean", tasks_status:gsub("%s+", "") == "")

    os.execute("rm -rf " .. dir)
end

-- ── Review regressions ─────────────────────────────────────────────────────

local function sh(cmd) return run_cmd(cmd) end
local function q(x) return "'" .. tostring(x):gsub("'", "'\\''") .. "'" end

-- A code repo with one commit, plus an orphan tasks worktree via tm init.
local function repo_with_tasks(prefix)
    local dir = make_temp_dir(prefix)
    sh(string.format("cd %s && git init -q -b main && echo code > app.c && git add app.c && git commit -qm init", dir))
    local out, code = run_cmd(string.format("cd %s && %s init --orphan", dir, abs_tm))
    return dir, out, code
end

do
    -- 1. A plain directory inside a larger repository is refused: nothing
    -- is staged or committed in the enclosing repository.
    local dir = make_temp_dir("tmsync_plain")
    sh(string.format("cd %s && git init -q -b main && echo code > app.c && git add app.c && git commit -qm init", dir))
    sh(string.format("mkdir %s/.tasks && echo '# Current Sprint' > %s/.tasks/active.tm.md", dir, dir))
    sh(string.format("cd %s && echo wip >> app.c && echo secret > private.txt", dir))
    local out, code = run_cmd(string.format("cd %s && %s sync", dir, abs_tm))
    local log = sh(string.format("cd %s && git rev-list --count HEAD", dir))
    local status = sh(string.format("cd %s && git status --porcelain", dir))
    check("safety", "plain directory inside a repo is refused", code ~= 0 and out:find("not the top level", 1, true) ~= nil, out)
    check("safety", "no commit made in the enclosing repo", log:match("^1%s*$") ~= nil, log)
    check("safety", "nothing staged in the enclosing repo",
        status:find("?? private.txt", 1, true) ~= nil and status:find(" M app.c", 1, true) ~= nil, status)
    os.execute("rm -rf " .. dir)
end

do
    -- 3. The commit message is passed literally, never through the shell.
    local dir = repo_with_tasks("tmsync_msg")
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] x\n")
    local msg = 'costs $HOME `echo pwned` "quoted" it\'s'
    local out, code = run_cmd(string.format("cd %s && %s sync -m %s", dir, abs_tm, q(msg)))
    local logged = sh(string.format("cd %s/.tasks && git log -1 --format=%%s", dir))
    check("message", "commit message is recorded literally", code == 0 and logged:gsub("%s+$", "") == msg, out .. " / " .. logged)
    os.execute("rm -rf " .. dir)
end

do
    -- 8. Hooks run; a failing hook fails the sync and its output is shown.
    local dir = repo_with_tasks("tmsync_hook")
    sh(string.format("mkdir %s/hooks && printf '#!/bin/sh\\necho HOOK-RAN >> %s/hook.log\\n' > %s/hooks/pre-commit && chmod +x %s/hooks/pre-commit",
        dir, dir, dir, dir))
    sh(string.format("cd %s && git config core.hooksPath %s/hooks", dir, dir))
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] hooked\n")
    local out, code = run_cmd(string.format("cd %s && %s sync -m one", dir, abs_tm))
    check("hooks", "pre-commit hook runs on tm sync", code == 0 and (read_file(dir .. "/hook.log") or ""):find("HOOK-RAN", 1, true) ~= nil, out)

    sh(string.format("printf '#!/bin/sh\\necho rejected-by-test-hook >&2\\nexit 1\\n' > %s/hooks/pre-commit", dir))
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] blocked\n")
    out, code = run_cmd(string.format("cd %s && %s sync -m two", dir, abs_tm))
    check("hooks", "a rejecting hook fails tm sync with the hook's output", code ~= 0 and out:find("rejected-by-test-hook", 1, true) ~= nil, out)
    local last = sh(string.format("cd %s/.tasks && git log -1 --format=%%s", dir))
    check("hooks", "nothing committed when the hook rejects", last:match("^one") ~= nil, last)
    os.execute("rm -rf " .. dir)
end

do
    -- 6. --push sets the upstream on the first push; later pushes reuse it.
    local dir = repo_with_tasks("tmsync_push")
    sh(string.format("git init -q --bare -b main %s/origin.git && cd %s && git remote add origin %s/origin.git", dir, dir, dir))
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] pushed\n")
    local out, code = run_cmd(string.format("cd %s && %s sync -m first -p", dir, abs_tm))
    local remote_log = sh(string.format("git --git-dir=%s/origin.git log --format=%%s tasks", dir))
    check("push", "first --push succeeds and creates the remote branch", code == 0 and remote_log:find("first", 1, true) ~= nil, out .. remote_log)
    local upstream = sh(string.format("cd %s/.tasks && git rev-parse --abbrev-ref @{u}", dir))
    check("push", "first --push sets the upstream", upstream:match("^origin/tasks") ~= nil, upstream)
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] pushed again\n")
    out, code = run_cmd(string.format("cd %s && %s sync -m second -p", dir, abs_tm))
    remote_log = sh(string.format("git --git-dir=%s/origin.git log -1 --format=%%s tasks", dir))
    check("push", "later --push reuses the upstream", code == 0 and remote_log:match("^second") ~= nil, out .. remote_log)

    -- A failing commit shows git's own reason.
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] no identity\n")
    sh(string.format("cd %s && git config user.useConfigOnly true", dir))
    out, code = run_cmd(string.format("cd %s && env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL EMAIL= %s sync -m x", dir, abs_tm))
    check("errors", "commit failure shows git's message", code ~= 0 and out:lower():find("identity", 1, true) ~= nil, out)
    os.execute("rm -rf " .. dir)
end

do
    -- A hook that itself runs a locking tm command (as a validating
    -- pre-commit hook does with `tm validate --fix`) must not deadlock
    -- against tm sync: sync holds the lock only while staging.
    local dir = repo_with_tasks("tmsync_hook_tm")
    sh(string.format("mkdir %s/hooks && printf '#!/bin/sh\\nfor f in $(git diff --cached --name-only -- \"*.tm.md\"); do lua %s/src/tm validate --fix \"$f\" || exit 1; git add \"$f\"; done\\n' > %s/hooks/pre-commit && chmod +x %s/hooks/pre-commit && cd %s && git config core.hooksPath %s/hooks",
        dir, abs_root, dir, dir, dir, dir))
    write_file(dir .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] validated by hook\n")
    local out, code = run_cmd(string.format("cd %s && %s sync -m validated", dir, abs_tm))
    local last = sh(string.format("cd %s/.tasks && git log -1 --format=%%s", dir))
    check("hooks", "hook running tm validate --fix does not hit sync's lock", code == 0 and last:match("^validated") ~= nil, out)
    os.execute("rm -rf " .. dir)
end

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
