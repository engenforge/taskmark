#!/usr/bin/env lua
-- tests/tminit_test.lua — unit + end-to-end tests for tminit.lua and `tm init`
--
-- Self-contained runner (mirroring tests/tmsweep_test.lua style).


-- Run hermetically: re-exec under an isolated git environment so the
-- developer's global, system, and GIT_CONFIG_COUNT-injected git config
-- (identity, hooks, signing, defaults) can
-- neither break nor be exercised by these tests. Hooks under test are
-- installed per repository via core.hooksPath.
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

local script_dir = (arg[0] or "./tests/tminit_test.lua"):match("^(.*)/[^/]+$") or "."
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

local function run_tminit_cli(args_str)
    local tminit = script_dir .. "/../src/tminit.lua"
    return run_cmd(string.format("lua %s %s", tminit, args_str or ""))
end

local function run_tm(args_str)
    local tm = script_dir .. "/../src/tm"
    return run_cmd(string.format("lua %s %s", tm, args_str or ""))
end

local function make_temp_dir(prefix)
    local dir = string.format("/tmp/%s_%d_%d", prefix or "tminit_test", os.time(), math.random(100000, 999999))
    os.execute("mkdir -p " .. dir)
    return dir
end

-- ── 1. Fresh directory initialization via `tm init --tasks-dir` ──────────────

do
    local dir = make_temp_dir("tminit_fresh")
    local tasks_dir = dir .. "/.tasks"
    local output, exit_code = run_tm(string.format("init --tasks-dir %s", tasks_dir))

    check("fresh_init", "exits 0", exit_code == 0)
    check("fresh_init", "active.tm.md created", (read_file(tasks_dir .. "/active.tm.md") ~= nil))
    check("fresh_init", "future.tm.md created", (read_file(tasks_dir .. "/future.tm.md") ~= nil))
    check("fresh_init", "completed.tm.md created", (read_file(tasks_dir .. "/completed.tm.md") ~= nil))

    -- Output messages
    check("fresh_init", "reports Created for active.tm.md", output:match("Created " .. tasks_dir .. "/active.tm.md") ~= nil)
    check("fresh_init", "reports Created for future.tm.md", output:match("Created " .. tasks_dir .. "/future.tm.md") ~= nil)
    check("fresh_init", "reports Created for completed.tm.md", output:match("Created " .. tasks_dir .. "/completed.tm.md") ~= nil)

    -- Content checks
    local active_content = read_file(tasks_dir .. "/active.tm.md")
    local expected_active = "# Current Sprint\n"
    check("fresh_init", "active.tm.md has exact starter content", active_content == expected_active)

    local future_content = read_file(tasks_dir .. "/future.tm.md")
    local expected_future = "# Planned Work\n"
    check("fresh_init", "future.tm.md has exact starter content", future_content == expected_future)

    local completed_content = read_file(tasks_dir .. "/completed.tm.md")
    local expected_completed = "# Completed Archive\n"
    check("fresh_init", "completed.tm.md has exact starter content", completed_content == expected_completed)

    -- Spec validation
    local _, val_act = run_tm(string.format("validate %s/active.tm.md", tasks_dir))
    check("fresh_init", "active.tm.md passes tm validate", val_act == 0)

    local _, val_fut = run_tm(string.format("validate %s/future.tm.md", tasks_dir))
    check("fresh_init", "future.tm.md passes tm validate", val_fut == 0)

    local _, val_comp = run_tm(string.format("validate %s/completed.tm.md", tasks_dir))
    check("fresh_init", "completed.tm.md passes tm validate", val_comp == 0)

    os.execute("rm -rf " .. dir)
end

-- ── 2. Idempotence / No-clobber on rerun ──────────────────────────────────────

do
    local dir = make_temp_dir("tminit_idempotent")
    local tasks_dir = dir .. "/.tasks"

    -- First run
    run_tm(string.format("init --tasks-dir %s", tasks_dir))
    local active_1 = read_file(tasks_dir .. "/active.tm.md")
    local future_1 = read_file(tasks_dir .. "/future.tm.md")
    local completed_1 = read_file(tasks_dir .. "/completed.tm.md")

    -- Second run
    local output2, exit_code2 = run_tm(string.format("init --tasks-dir %s", tasks_dir))
    check("idempotence", "rerun exits 0", exit_code2 == 0)
    check("idempotence", "reports Skipped for active.tm.md", output2:match("Skipped " .. tasks_dir .. "/active.tm.md %(already exists%)") ~= nil)
    check("idempotence", "reports Skipped for future.tm.md", output2:match("Skipped " .. tasks_dir .. "/future.tm.md %(already exists%)") ~= nil)
    check("idempotence", "reports Skipped for completed.tm.md", output2:match("Skipped " .. tasks_dir .. "/completed.tm.md %(already exists%)") ~= nil)

    -- Byte-for-byte unchanged
    check("idempotence", "active.tm.md byte-for-byte unchanged", read_file(tasks_dir .. "/active.tm.md") == active_1)
    check("idempotence", "future.tm.md byte-for-byte unchanged", read_file(tasks_dir .. "/future.tm.md") == future_1)
    check("idempotence", "completed.tm.md byte-for-byte unchanged", read_file(tasks_dir .. "/completed.tm.md") == completed_1)

    os.execute("rm -rf " .. dir)
end

-- ── 3. Partial pre-existing directory (only active.tm.md pre-exists) ────────────

do
    local dir = make_temp_dir("tminit_partial")
    local tasks_dir = dir .. "/.tasks"
    os.execute("mkdir -p " .. tasks_dir)

    -- Custom active.tm.md with tasks
    local custom_active = [[# Current Sprint

- [ ] custom existing task
    > **Context:** Do not overwrite me.
]]
    write_file(tasks_dir .. "/active.tm.md", custom_active)

    local output, exit_code = run_tm(string.format("init --tasks-dir %s", tasks_dir))
    check("partial_init", "exits 0", exit_code == 0)
    check("partial_init", "reports Skipped for active.tm.md", output:match("Skipped " .. tasks_dir .. "/active.tm.md %(already exists%)") ~= nil)
    check("partial_init", "reports Created for future.tm.md", output:match("Created " .. tasks_dir .. "/future.tm.md") ~= nil)
    check("partial_init", "reports Created for completed.tm.md", output:match("Created " .. tasks_dir .. "/completed.tm.md") ~= nil)

    -- active.tm.md is byte-for-byte untouched
    check("partial_init", "active.tm.md preserved byte-for-byte", read_file(tasks_dir .. "/active.tm.md") == custom_active)

    -- future.tm.md and completed.tm.md are created properly and pass validation
    local _, val_fut = run_tm(string.format("validate %s/future.tm.md", tasks_dir))
    check("partial_init", "created future.tm.md passes tm validate", val_fut == 0)
    local _, val_comp = run_tm(string.format("validate %s/completed.tm.md", tasks_dir))
    check("partial_init", "created completed.tm.md passes tm validate", val_comp == 0)

    os.execute("rm -rf " .. dir)
end

-- ── 4. Direct invocation of tminit.lua ───────────────────────────────────────

do
    local dir = make_temp_dir("tminit_direct")
    local tasks_dir = dir .. "/my_tasks"
    local output, exit_code = run_tminit_cli(string.format("--tasks-dir %s", tasks_dir))

    check("direct_invocation", "exits 0 when run directly", exit_code == 0)
    check("direct_invocation", "created files exist",
          read_file(tasks_dir .. "/active.tm.md") ~= nil and
          read_file(tasks_dir .. "/future.tm.md") ~= nil and
          read_file(tasks_dir .. "/completed.tm.md") ~= nil)

    os.execute("rm -rf " .. dir)
end

-- ── 5. Help flags (-h / --help) ──────────────────────────────────────────────

do
    local out_h, code_h = run_tm("init -h")
    check("help_flag", "tm init -h exits 0", code_h == 0)
    check("help_flag", "tm init -h contains Usage", out_h:match("Usage:") ~= nil)

    local out_help, code_help = run_tm("init --help")
    check("help_flag", "tm init --help exits 0", code_help == 0)
    check("help_flag", "tm init --help contains Usage", out_help:match("Usage:") ~= nil)

    local out_dir_h, code_dir_h = run_tminit_cli("-h")
    check("help_flag", "tminit.lua -h exits 0", code_dir_h == 0)
    check("help_flag", "tminit.lua -h contains Usage", out_dir_h:match("Usage:") ~= nil)
end

-- ── 6. Error handling (invalid options / missing args) ────────────────────────

do
    local out, code = run_tm("init --unknown-flag")
    check("errors", "unknown flag exits 1", code == 1)
    check("errors", "unknown flag prints error", out:match("Unknown option") ~= nil)

    local out_dir, code_dir = run_tm("init --tasks-dir")
    check("errors", "missing --tasks-dir arg exits 1", code_dir == 1)
    check("errors", "missing --tasks-dir arg prints error", out_dir:match("%-%-tasks%-dir requires an argument") ~= nil)

    local out_extra, code_extra = run_tm("init unexpected_pos_arg")
    check("errors", "unexpected argument exits 1", code_extra == 1)
    check("errors", "unexpected argument prints error", out_extra:match("Unexpected argument") ~= nil)
end

-- ── 7. Orphan worktree initialization via `tm init --orphan` ─────────────────

do
    local dir = make_temp_dir("tminit_orphan_not_git")
    local out, code = run_cmd(string.format("cd %s && %s init --orphan", dir, abs_tm))
    check("orphan_init", "non-git repo exits 1", code == 1)
    check("orphan_init", "non-git repo reports error", out:match("requires an initialized git repository") ~= nil)
    os.execute("rm -rf " .. dir)

    local git_dir = make_temp_dir("tminit_orphan_git")
    os.execute(string.format([[
        cd %s && \
        git init -q -b main && \
        git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "initial commit"
    ]], git_dir))

    local out_orph, code_orph = run_cmd(string.format("cd %s && %s init --orphan", git_dir, abs_tm))
    check("orphan_init", "init --orphan exits 0", code_orph == 0)
    check("orphan_init", ".gitignore created/updated", read_file(git_dir .. "/.gitignore") ~= nil)
    local gitignore = read_file(git_dir .. "/.gitignore") or ""
    check("orphan_init", ".gitignore contains /.tasks/", gitignore:match("/%.tasks/") ~= nil)

    check("orphan_init", ".taskmarkrc created/updated", read_file(git_dir .. "/.taskmarkrc") ~= nil)
    local taskmarkrc = read_file(git_dir .. "/.taskmarkrc") or ""
    check("orphan_init", ".taskmarkrc sets tasks_dir: .tasks", taskmarkrc:match("tasks_dir:%s*%.tasks") ~= nil)

    -- Worktree check
    local worktree_branch, _ = run_cmd(string.format("cd %s/.tasks && git branch --show-current", git_dir))
    worktree_branch = worktree_branch:gsub("%s+$", "")
    check("orphan_init", "mounted worktree is on branch tasks", worktree_branch == "tasks")

    -- Starter files exist
    check("orphan_init", "active.tm.md exists in worktree", read_file(git_dir .. "/.tasks/active.tm.md") ~= nil)
    check("orphan_init", "future.tm.md exists in worktree", read_file(git_dir .. "/.tasks/future.tm.md") ~= nil)
    check("orphan_init", "completed.tm.md exists in worktree", read_file(git_dir .. "/.tasks/completed.tm.md") ~= nil)

    -- Initial commit on orphan branch exists
    local commit_msg, _ = run_cmd(string.format("cd %s/.tasks && git log -1 --pretty=%%s", git_dir))
    check("orphan_init", "initial commit created on orphan branch", commit_msg:match("Initialize") ~= nil)

    -- git status on main branch ignores .tasks/
    local git_status, _ = run_cmd(string.format("cd %s && git status --porcelain", git_dir))
    check("orphan_init", "git status on main does not show .tasks/", git_status:match("%.tasks") == nil)

    -- Idempotence: rerun init --orphan
    local out_rerun, code_rerun = run_cmd(string.format("cd %s && %s init --orphan", git_dir, abs_tm))
    check("orphan_init", "rerun init --orphan exits 0", code_rerun == 0)

    os.execute("rm -rf " .. git_dir)
end

-- ── 8. Custom branch for `tm init --orphan [BRANCH]` ─────────────────────────

do
    local git_dir = make_temp_dir("tminit_orphan_custom")
    os.execute(string.format([[
        cd %s && \
        git init -q -b main && \
        git -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "initial commit"
    ]], git_dir))

    local out_custom, code_custom = run_cmd(string.format("cd %s && %s init --orphan my-task-branch", git_dir, abs_tm))
    check("orphan_custom", "init --orphan custom-branch exits 0", code_custom == 0)

    local branch_out, _ = run_cmd(string.format("cd %s/.tasks && git branch --show-current", git_dir))
    branch_out = branch_out:gsub("%s+$", "")
    check("orphan_custom", "mounted worktree is on custom branch", branch_out == "my-task-branch")

    os.execute("rm -rf " .. git_dir)
end

-- ── 9. Orphan init review regressions ────────────────────────────────────────

local function sh(cmd) return run_cmd(cmd) end
local function code_repo(prefix)
    local dir = make_temp_dir(prefix)
    sh(string.format("cd %s && git init -q -b main && echo code > app.c && git add app.c && git commit -qm init", dir))
    return dir
end

do
    -- 5. An existing plain directory is not "already mounted".
    local dir = code_repo("tminit_plain")
    sh("mkdir " .. dir .. "/.tasks")
    local out, code = run_cmd(string.format("cd %s && %s init --orphan", dir, abs_tm))
    local branches = sh(string.format("cd %s && git branch --list", dir))
    check("orphan_safety", "existing plain directory is refused", code ~= 0 and out:find("not a git worktree", 1, true) ~= nil, out)
    check("orphan_safety", "no orphan branch created", not branches:find("tasks", 1, true), branches)
    os.execute("rm -rf " .. dir)
end

do
    -- 2. The orphan branch never contains the code branch's files, even
    -- on a git without `worktree add --orphan` (< 2.42), simulated here.
    local dir = code_repo("tminit_oldgit")
    sh(string.format("mkdir %s/fakebin && printf '#!/bin/sh\\ncase \" $* \" in *\" worktree add \"*\" --orphan \"*) echo \"error: unknown option orphan\" >&2; exit 129;; esac\\nexec %s \"$@\"\\n' > %s/fakebin/git && chmod +x %s/fakebin/git",
        dir, (io.popen("command -v git"):read("*l")), dir, dir))
    local out, code = run_cmd(string.format("cd %s && PATH=%s/fakebin:$PATH %s init --orphan", dir, dir, abs_tm))
    local files = sh(string.format("cd %s && git ls-tree -r --name-only tasks", dir))
    check("orphan_oldgit", "init succeeds without worktree add --orphan", code == 0, out)
    check("orphan_oldgit", "tasks branch holds only taskmark files",
        files:find("active.tm.md", 1, true) ~= nil and not files:find("app.c", 1, true), files)
    local wt = sh(string.format("ls -A %s/.tasks", dir))
    check("orphan_oldgit", "worktree contains no code-branch files", not wt:find("app.c", 1, true), wt)
    local wt_status = sh(string.format("cd %s/.tasks && git status --porcelain", dir))
    check("orphan_oldgit", "worktree is clean after init", wt_status:gsub("%s+", "") == "", wt_status)
    local roots = sh(string.format("cd %s && git rev-list --max-parents=0 tasks", dir))
    local main_root = sh(string.format("cd %s && git rev-list --max-parents=0 main", dir))
    check("orphan_oldgit", "tasks branch shares no history with main", roots ~= main_root, roots)
    os.execute("rm -rf " .. dir)
end

do
    -- 4. A collaborator's clone checks out the existing remote branch
    -- instead of starting an unrelated one.
    local base = make_temp_dir("tminit_collab")
    sh(string.format("git init -q --bare -b main %s/origin.git", base))
    local a = base .. "/a"
    sh(string.format("git init -q -b main %s && cd %s && echo code > app.c && git add app.c && git commit -qm init && git remote add origin %s/origin.git", a, a, base))
    run_cmd(string.format("cd %s && %s init --orphan", a, abs_tm))
    write_file(a .. "/.tasks/active.tm.md", "# Current Sprint\n\n- [ ] Task from A\n")
    sh(string.format("cd %s/.tasks && git commit -qam 'add task' && git push -q -u origin tasks && cd .. && git push -q origin main", a))

    local b = base .. "/b"
    sh(string.format("git clone -q %s/origin.git %s", base, b))
    local out, code = run_cmd(string.format("cd %s && %s init --orphan", b, abs_tm))
    check("orphan_collab", "init in a clone exits 0", code == 0, out)
    check("orphan_collab", "clone sees the existing tasks", (read_file(b .. "/.tasks/active.tm.md") or ""):find("Task from A", 1, true) ~= nil, out)
    local mb = sh(string.format("cd %s && git merge-base tasks origin/tasks && git rev-parse origin/tasks", b))
    local x, y = mb:match("^(%x+)%s+(%x+)")
    check("orphan_collab", "local tasks is origin/tasks, not an unrelated branch", x ~= nil and x == y, mb)
    local up = sh(string.format("cd %s/.tasks && git rev-parse --abbrev-ref @{u}", b))
    check("orphan_collab", "local tasks tracks origin/tasks", up:match("^origin/tasks") ~= nil, up)
    os.execute("rm -rf " .. base)
end

do
    -- 7. Run from a subdirectory: refused, nothing created.
    local dir = code_repo("tminit_subdir")
    sh("mkdir " .. dir .. "/sub")
    local out, code = run_cmd(string.format("cd %s/sub && %s init --orphan", dir, abs_tm))
    check("orphan_paths", "subdirectory is refused with the repo root named", code ~= 0 and out:find("repository root", 1, true) ~= nil, out)
    check("orphan_paths", "no worktree, .gitignore or .taskmarkrc created",
        read_file(dir .. "/.gitignore") == nil and read_file(dir .. "/.taskmarkrc") == nil
        and not sh(string.format("cd %s && git worktree list", dir)):find("/sub/", 1, true), out)
    os.execute("rm -rf " .. dir)
end

do
    -- 8 + 11. The initial commit runs hooks; changed files on the code
    -- branch are named for the user to commit.
    local dir = code_repo("tminit_hooks")
    sh(string.format("mkdir %s/hooks && printf '#!/bin/sh\\necho HOOK-RAN >> %s/hook.log\\n' > %s/hooks/pre-commit && chmod +x %s/hooks/pre-commit && cd %s && git config core.hooksPath %s/hooks",
        dir, dir, dir, dir, dir, dir))
    local out, code = run_cmd(string.format("cd %s && %s init --orphan", dir, abs_tm))
    check("orphan_hooks", "initial tasks commit runs the pre-commit hook",
        code == 0 and (read_file(dir .. "/hook.log") or ""):find("HOOK-RAN", 1, true) ~= nil, out)
    check("orphan_notice", "reports .gitignore and .taskmarkrc as needing a commit",
        out:find(".gitignore", 1, true) ~= nil and out:find(".taskmarkrc", 1, true) ~= nil and out:find("commit", 1, true) ~= nil, out)
    os.execute("rm -rf " .. dir)
end

-- ── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
