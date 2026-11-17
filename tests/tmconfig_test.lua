#!/usr/bin/env lua
-- tests/tmconfig_test.lua — unit + end-to-end tests for tmconfig.lua
-- (SPEC-TASKMARK-06 §9 configuration resolution).
--
-- Self-contained runner (mirroring tests/tmsweep_test.lua / tminit_test.lua
-- style).

-- Run hermetically (see tests/tmsync_test.lua): the worktree cases make
-- commits in scratch repositories, which must not pick up the user's
-- global, system, or environment-injected git configuration (signing,
-- hooks, identity) -- a signing key would otherwise prompt for its PIN.
package.path = ((arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local HAVE_GIT = require("testgit").isolate()

local script_dir = (arg[0] or "./tests/tmconfig_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. script_dir .. "/../vendor/?.lua;" .. package.path

local tmconfig = require("tmconfig")

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

local function make_temp_dir(prefix)
    local dir = string.format("/tmp/%s_%d_%d", prefix or "tmconfig_test", os.time(), math.random(100000, 999999))
    os.execute("mkdir -p " .. dir)
    return dir
end

math.randomseed(os.time())

-- Absent global config file, kept out of the way of every test below via
-- the global_config_path override seam.
local NO_GLOBAL = "/nonexistent/taskmark/config"

-- ── M.load ───────────────────────────────────────────────────────────────

do
    local missing = tmconfig.load("/nonexistent/path/.taskmarkrc")
    check("load", "missing file returns {}", next(missing) == nil)
end

do
    local dir = make_temp_dir("tmconfig_load")
    local path = dir .. "/.taskmarkrc"

    write_file(path, "")
    check("load", "empty file returns {}", next(tmconfig.load(path)) == nil)

    write_file(path, "not a key value line {{{")
    check("load", "malformed line returns {}", next(tmconfig.load(path)) == nil)

    write_file(path, "tasks_dir: tracking\n# a comment\n\nunknown_key: ignored\n")
    local cfg = tmconfig.load(path)
    check("load", "recognized key is kept", cfg.tasks_dir == "tracking")
    check("load", "unrecognized key is dropped", cfg.unknown_key == nil)
    check("load", "comment and blank lines are relaxed away (not a parse error)",
          next(cfg) ~= nil)

    write_file(path, 'tasks_dir: ""\nactive_file: now.tm.md\n')
    cfg = tmconfig.load(path)
    check("load", "empty-string value is dropped (falls through to default later)", cfg.tasks_dir == nil)
    check("load", "sibling valid key still parsed", cfg.active_file == "now.tm.md")

    write_file(path, "tasks_dir: one\ntasks_dir: two\n")
    check("load", "duplicate key (a reader error) falls through to {}", next(tmconfig.load(path)) == nil)

    os.execute("rm -rf " .. dir)
end

-- ── M.resolve ────────────────────────────────────────────────────────────

do
    local cfg = tmconfig.resolve({ config_path = "/nonexistent/.taskmarkrc", global_config_path = NO_GLOBAL })
    check("resolve", "no file, no overrides: tasks_dir default", cfg.tasks_dir == ".tasks")
    check("resolve", "no file, no overrides: active_path derived", cfg.active_path == ".tasks/active.tm.md")
    check("resolve", "no file, no overrides: future_path derived", cfg.future_path == ".tasks/future.tm.md")
    check("resolve", "no file, no overrides: completed_path derived", cfg.completed_path == ".tasks/completed.tm.md")
    check("resolve", "no file, no overrides: archive_dir default", cfg.archive_dir == "archive")
    check("resolve", "no file, no overrides: archive_max_bytes default", cfg.archive_max_bytes == "0")
end

do
    local dir = make_temp_dir("tmconfig_resolve")
    local path = dir .. "/.taskmarkrc"
    write_file(path, [[
tasks_dir: tracking
active_file: now.tm.md
future_file: later.tm.md
completed_file: done.tm.md
archive_dir: history
archive_max_bytes: 524288
]])

    local cfg = tmconfig.resolve({ config_path = path, global_config_path = NO_GLOBAL })
    check("resolve", "file config: tasks_dir", cfg.tasks_dir == "tracking")
    check("resolve", "file config: active_path", cfg.active_path == "tracking/now.tm.md")
    check("resolve", "file config: future_path", cfg.future_path == "tracking/later.tm.md")
    check("resolve", "file config: completed_path", cfg.completed_path == "tracking/done.tm.md")
    check("resolve", "file config: archive_dir", cfg.archive_dir == "history")
    check("resolve", "file config: archive_max_bytes", cfg.archive_max_bytes == "524288")

    -- Explicit overrides win over the file, per key.
    local cfg2 = tmconfig.resolve({ config_path = path, global_config_path = NO_GLOBAL, tasks_dir = "elsewhere" })
    check("resolve", "explicit override beats file config for the overridden key",
          cfg2.tasks_dir == "elsewhere")
    check("resolve", "explicit override leaves other file-configured keys alone",
          cfg2.active_path == "elsewhere/now.tm.md")

    -- Partial config file: unset keys still fall back to built-in defaults.
    write_file(path, "tasks_dir: tracking\n")
    local cfg3 = tmconfig.resolve({ config_path = path, global_config_path = NO_GLOBAL })
    check("resolve", "partial file config: configured key used", cfg3.tasks_dir == "tracking")
    check("resolve", "partial file config: unconfigured key keeps built-in default",
          cfg3.active_file == "active.tm.md")
    check("resolve", "partial file config: derived path combines the two",
          cfg3.active_path == "tracking/active.tm.md")

    os.execute("rm -rf " .. dir)
end

-- Per-key resolution across local and global files: a local file setting
-- only tasks_dir must leave every other key to the global file, not to the
-- built-in default.

do
    local dir = make_temp_dir("tmconfig_perkey")
    local local_path = dir .. "/.taskmarkrc"
    local global_path = dir .. "/global_config"

    write_file(local_path, "tasks_dir: tracking\n")
    write_file(global_path, [[
active_file: now.tm.md
archive_dir: history
completed_file: finish.tm.md
]])

    local cfg = tmconfig.resolve({ config_path = local_path, global_config_path = global_path })
    check("resolve", "per-key: local file's key wins", cfg.tasks_dir == "tracking")
    check("resolve", "per-key: global file fills a key the local file left unset",
          cfg.active_file == "now.tm.md")
    check("resolve", "per-key: global file's archive_dir used", cfg.archive_dir == "history")
    check("resolve", "per-key: global file's completed_file used", cfg.completed_file == "finish.tm.md")
    check("resolve", "per-key: key set nowhere keeps the built-in default",
          cfg.future_file == "future.tm.md")
    check("resolve", "per-key: derived active_path combines local tasks_dir with global active_file",
          cfg.active_path == "tracking/now.tm.md")

    -- Local file overrides the same key when both files set it.
    write_file(local_path, "active_file: local.tm.md\n")
    local cfg2 = tmconfig.resolve({ config_path = local_path, global_config_path = global_path })
    check("resolve", "per-key: local file beats global file for a shared key",
          cfg2.active_file == "local.tm.md")

    os.execute("rm -rf " .. dir)
end

do
    -- XDG_CONFIG_HOME / HOME fallback path construction.
    check("global_config_path", "uses M.global_config_path() as the default global lookup",
          type(tmconfig.global_config_path()) == "string")
end

-- ── End-to-end: .taskmarkrc picked up from the current directory ──────────

do
    local dir = make_temp_dir("tmconfig_e2e")
    -- Absolute path: these scenarios `cd` into `dir` before invoking `tm` (to
    -- exercise .taskmarkrc discovery via the current directory), which
    -- would break a script_dir-relative path.
    local tm = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")

    write_file(dir .. "/.taskmarkrc", [[
tasks_dir: tracking
active_file: now.tm.md
future_file: later.tm.md
completed_file: done.tm.md
archive_dir: history
]])

    local out, code = run_cmd(string.format("cd %s && lua %s init", dir, tm))
    check("e2e", "tm init honors .taskmarkrc: exit 0", code == 0)
    check("e2e", "tm init honors .taskmarkrc: creates tracking/now.tm.md",
          read_file(dir .. "/tracking/now.tm.md") ~= nil)
    check("e2e", "tm init honors .taskmarkrc: creates tracking/later.tm.md",
          read_file(dir .. "/tracking/later.tm.md") ~= nil)
    check("e2e", "tm init honors .taskmarkrc: creates tracking/done.tm.md",
          read_file(dir .. "/tracking/done.tm.md") ~= nil)

    out, code = run_cmd(string.format("cd %s && lua %s validate", dir, tm))
    check("e2e", "tm validate with no argument resolves configured active file", code == 0)
    check("e2e", "tm validate with no argument reports the configured path",
          out:match("tracking/now%.tm%.md") ~= nil)

    -- --tasks-dir on the CLI overrides tasks_dir from .taskmarkrc, but the
    -- configured filenames still apply within that overridden directory.
    out, code = run_cmd(string.format("cd %s && lua %s init --tasks-dir override", dir, tm))
    check("e2e", "--tasks-dir overrides .taskmarkrc's tasks_dir: exit 0", code == 0)
    check("e2e", "--tasks-dir overrides .taskmarkrc's tasks_dir: creates override/now.tm.md",
          read_file(dir .. "/override/now.tm.md") ~= nil)

    -- Seed a completed task in the configured active file and confirm
    -- sweep/archive resolve the configured paths with no positional args.
    write_file(dir .. "/tracking/now.tm.md", [[
# Current Sprint

- [x] Finished thing
    > **Completed:** 2026-08-01
]])
    out, code = run_cmd(string.format("cd %s && lua %s sweep", dir, tm))
    check("e2e", "tm sweep with no positional args resolves configured paths: exit 0", code == 0)
    check("e2e", "tm sweep moved the task into the configured completed file",
          (read_file(dir .. "/tracking/done.tm.md") or ""):match("Finished thing") ~= nil)

    -- Age the swept task out and confirm archive lands under the
    -- configured archive_dir name.
    local completed_body = "# Completed Archive\n\n"
    for n = 2, 1, -1 do
        completed_body = completed_body ..
            string.format("- [x] r%d\n    > **Completed:** 2026-08-2%d\n\n", n, n % 10)
    end
    completed_body = completed_body .. "- [x] old thing\n    > **Completed:** 2026-01-01\n"
    write_file(dir .. "/tracking/done.tm.md", completed_body)

    out, code = run_cmd(string.format("cd %s && lua %s archive", dir, tm))
    check("e2e", "tm archive with no flags/args resolves configured paths: exit 0", code == 0)
    check("e2e", "tm archive uses the configured archive_dir name",
          read_file(dir .. "/tracking/history/2026/2026-01.tm.md") ~= nil)

    -- archive_max_bytes in .taskmarkrc is honored by tm archive, and --max-bytes overrides it.
    local today = os.date("!%Y-%m-%d")
    write_file(dir .. "/.taskmarkrc", "tasks_dir: tracking\ncompleted_file: done.tm.md\narchive_dir: history\narchive_max_bytes: 80\n")
    write_file(dir .. "/tracking/done.tm.md", "# Completed Archive\n\n"
        .. string.format("- [x] newest\n    > **Completed:** %s\n\n", today)
        .. string.format("- [x] older\n    > **Completed:** %s\n", today))
    out, code = run_cmd(string.format("cd %s && lua %s archive", dir, tm))
    check("e2e", "tm archive honors archive_max_bytes from .taskmarkrc",
          code == 0 and not (read_file(dir .. "/tracking/done.tm.md") or ""):match("older"))

    -- Invalid archive_max_bytes in .taskmarkrc fails tm archive, but does not break tm sweep.
    write_file(dir .. "/.taskmarkrc", "tasks_dir: tracking\nactive_file: now.tm.md\ncompleted_file: done.tm.md\narchive_max_bytes: 512k\n")
    write_file(dir .. "/tracking/now.tm.md", "# Current Sprint\n\n- [x] Sweepable\n    > **Completed:** 2026-08-01\n")
    out, code = run_cmd(string.format("cd %s && lua %s sweep", dir, tm))
    check("e2e", "invalid archive_max_bytes in .taskmarkrc does not break tm sweep", code == 0, out)
    out, code = run_cmd(string.format("cd %s && lua %s archive", dir, tm))
    check("e2e", "invalid archive_max_bytes in .taskmarkrc fails",
          code ~= 0 and out:match("archive_max_bytes") ~= nil, out)

    -- A malformed config file is never fatal -- falls back to conventional
    -- defaults exactly as if no config file existed.
    write_file(dir .. "/.taskmarkrc", "tasks_dir: one\ntasks_dir: two\n")
    out, code = run_cmd(string.format("cd %s && lua %s init --tasks-dir fallback_check", dir, tm))
    check("e2e", "malformed .taskmarkrc is non-fatal: exit 0", code == 0)
    check("e2e", "malformed .taskmarkrc: conventional filename used",
          read_file(dir .. "/fallback_check/active.tm.md") ~= nil)

    os.execute("rm -rf " .. dir)
end

-- ── Default tasks_dir: .tasks ───────────────────────────────────

do
    local dir = make_temp_dir("tmconfig_default")
    local tm = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")

    -- 1. In a fresh directory with no tasks_dir configured:
    -- `tm init` defaults to creating .tasks/ starter files
    local out, code = run_cmd(string.format("cd %s && lua %s init", dir, tm))
    check("default_dir", "fresh init defaults to .tasks: exit 0", code == 0)
    check("default_dir", "creates .tasks/active.tm.md", read_file(dir .. "/.tasks/active.tm.md") ~= nil)

    -- `tm validate` with no args resolves .tasks/active.tm.md
    out, code = run_cmd(string.format("cd %s && lua %s validate", dir, tm))
    check("default_dir", "validate finds .tasks/active.tm.md: exit 0", code == 0)
    check("default_dir", "validate output mentions .tasks/active.tm.md", out:match("%.tasks/active%.tm%.md") ~= nil)

    os.execute("rm -rf " .. dir)
end

-- ── Legacy doc/tasks fallback ───────────────────────────────────

do
    local tm = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")
    local function init_in(dir)
        return run_cmd(string.format("cd %s && XDG_CONFIG_HOME=/nonexistent lua %s init", dir, tm))
    end

    -- A pre-0.4 project with only doc/tasks/ keeps resolving there unconfigured.
    local dir = make_temp_dir("tmconfig_legacy")
    os.execute("mkdir -p " .. dir .. "/doc/tasks")
    local f = io.open(dir .. "/doc/tasks/active.tm.md", "w")
    f:write("# Current Sprint\n")
    f:close()
    local out, code = init_in(dir)
    check("legacy_dir", "only doc/tasks exists: init exits 0", code == 0, out)
    check("legacy_dir", "only doc/tasks exists: resolves doc/tasks",
        out:match("Skipped doc/tasks/active%.tm%.md") ~= nil and not out:match("%.tasks/"), out)
    check("legacy_dir", "only doc/tasks exists: no .tasks/ created",
        read_file(dir .. "/.tasks/active.tm.md") == nil)
    os.execute("rm -rf " .. dir)

    -- Once .tasks/ exists it wins over the legacy directory.
    dir = make_temp_dir("tmconfig_legacy_both")
    os.execute("mkdir -p " .. dir .. "/doc/tasks " .. dir .. "/.tasks")
    out = init_in(dir)
    check("legacy_dir", "both exist: .tasks wins", out:match("Created %.tasks/active%.tm%.md") ~= nil, out)
    os.execute("rm -rf " .. dir)

    -- An explicitly configured tasks_dir is never second-guessed.
    dir = make_temp_dir("tmconfig_legacy_cfg")
    os.execute("mkdir -p " .. dir .. "/doc/tasks")
    f = io.open(dir .. "/.taskmarkrc", "w")
    f:write("tasks_dir: .tasks\n")
    f:close()
    out = init_in(dir)
    check("legacy_dir", "configured tasks_dir is not replaced by the fallback",
        out:match("Created %.tasks/active%.tm%.md") ~= nil, out)
    os.execute("rm -rf " .. dir)
end

-- ── Upward discovery of .taskmarkrc ─────────────────────────────

do
    local dir = make_temp_dir("tmconfig_upward")
    local tm = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")

    -- 1. Create a project root with .taskmarkrc naming doc/tasks
    write_file(dir .. "/.taskmarkrc", "tasks_dir: doc/tasks\n")
    os.execute("mkdir -p " .. dir .. "/doc/tasks " .. dir .. "/src/sub")
    write_file(dir .. "/doc/tasks/active.tm.md", "# Current\n\n- [ ] Root task\n")
    write_file(dir .. "/doc/tasks/completed.tm.md", "# Completed\n")

    -- Invoke tm list from inside doc/tasks
    local out, code = run_cmd(string.format("cd %s/doc/tasks && lua %s list", dir, tm))
    check("upward", "tm list from inside doc/tasks succeeds: exit 0", code == 0, out)
    check("upward", "tm list from inside doc/tasks finds task", out:find("Root task", 1, true) ~= nil, out)

    -- Invoke tm list from inside deeply nested src/sub
    out, code = run_cmd(string.format("cd %s/src/sub && lua %s list", dir, tm))
    check("upward", "tm list from inside src/sub succeeds: exit 0", code == 0, out)
    check("upward", "tm list from inside src/sub finds task", out:find("Root task", 1, true) ~= nil, out)

    -- Invoke tm sweep from inside doc/tasks
    write_file(dir .. "/doc/tasks/active.tm.md", "# Current\n\n- [x] Swept task\n")
    out, code = run_cmd(string.format("cd %s/doc/tasks && lua %s sweep", dir, tm))
    check("upward", "tm sweep from inside doc/tasks succeeds: exit 0", code == 0, out)
    check("upward", "tm sweep moves task into completed.tm.md",
        (read_file(dir .. "/doc/tasks/completed.tm.md") or ""):find("Swept task", 1, true) ~= nil)

    -- 2. Upward search stops at Git repository boundary
    local outer = make_temp_dir("tmconfig_outer")
    write_file(outer .. "/.taskmarkrc", "tasks_dir: outer_tasks\n")
    local inner_repo = outer .. "/inner_repo"
    os.execute("mkdir -p " .. inner_repo .. "/.git " .. inner_repo .. "/sub")
    -- In inner_repo/sub, upward search stops at inner_repo (.git boundary),
    -- does not see outer/.taskmarkrc, and falls back to .tasks
    local cfg = tmconfig.resolve({ start_dir = inner_repo .. "/sub", global_config_path = NO_GLOBAL })
    check("upward", "upward search does not cross .git boundary", cfg.tasks_dir:find("outer_tasks") == nil)

    -- 3. In a Git repository with root .tasks/ and no .taskmarkrc:
    -- subdirectories resolve to the repository root .tasks/
    os.execute("mkdir -p " .. inner_repo .. "/.tasks")
    write_file(inner_repo .. "/.tasks/active.tm.md", "# Tasks\n\n- [ ] Inner task\n")
    out, code = run_cmd(string.format("cd %s/sub && lua %s list", inner_repo, tm))
    check("upward", "tm list in git subdir resolves root .tasks: exit 0", code == 0, out)
    check("upward", "tm list in git subdir finds inner task", out:find("Inner task", 1, true) ~= nil, out)

    -- 4. Worktree layout: orphan tasks branch mounted at doc/tasks (like Zoril)
    -- with .taskmarkrc at the repo root. The tasks worktree has a .git file.
    -- Upward search must recognise the enclosing repository and not stop early.
    if not HAVE_GIT then
        print("[SKIP] upward_worktree: git is not installed")
    else
        local wt_repo = make_temp_dir("tmconfig_wt_repo")
        os.execute("git -C " .. wt_repo .. " init -q")
        os.execute("git -C " .. wt_repo .. " config user.name tm-test && git -C " .. wt_repo .. " config user.email tm@example.invalid")
        write_file(wt_repo .. "/.taskmarkrc", "tasks_dir: doc/tasks\n")
        write_file(wt_repo .. "/README.md", "zoril\n")
        os.execute("git -C " .. wt_repo .. " add . && git -C " .. wt_repo .. " commit -q -m initial")
        -- Mount orphan tasks worktree at doc/tasks
        os.execute("git -C " .. wt_repo .. " worktree add -q --detach --no-checkout " .. wt_repo .. "/doc/tasks")
        os.execute("git -C " .. wt_repo .. "/doc/tasks symbolic-ref HEAD refs/heads/tasks")
        os.execute("git -C " .. wt_repo .. "/doc/tasks read-tree --empty")
        write_file(wt_repo .. "/doc/tasks/active.tm.md", "# Active\n\n- [ ] Pending worktree task\n\n- [x] Completed worktree task\n")
        write_file(wt_repo .. "/doc/tasks/completed.tm.md", "# Completed\n")

        out, code = run_cmd(string.format("cd %s/doc/tasks && lua %s list", wt_repo, tm))
        check("upward_worktree", "tm list inside mounted doc/tasks worktree succeeds: exit 0", code == 0, out)
        check("upward_worktree", "tm list inside mounted doc/tasks worktree finds task", out:find("Pending worktree task", 1, true) ~= nil, out)

        out, code = run_cmd(string.format("cd %s/doc/tasks && lua %s sweep --dry-run", wt_repo, tm))
        check("upward_worktree", "tm sweep --dry-run inside mounted doc/tasks worktree succeeds: exit 0", code == 0, out)
        check("upward_worktree", "tm sweep reports task to move", out:find("Completed worktree task", 1, true) ~= nil, out)
        os.execute("rm -rf " .. wt_repo)
    end

    os.execute("rm -rf " .. dir .. " " .. outer)
end

-- ── Code worktrees nested in their own repository ───────────────────────
--
-- Parallel work streams run as linked worktrees inside the main checkout
-- (build/<name>), and tm run there with no path arguments must use the
-- main checkout's .tasks: such a worktree is not a project boundary.

if not HAVE_GIT then
    print("[SKIP] nested_worktree: git is not installed")
else
    local tm = "lua " .. io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")

    local function count(text, pattern)
        local n = 0
        for _ in ("\n" .. text):gmatch("\n%s*" .. pattern) do n = n + 1 end
        return n
    end
    local function pending(text) return count(text, "%- %[ %]") end
    local function completed(text) return count(text, "%- %[x%]") end

    -- A repository with one commit and two linked worktrees, build/s1 and
    -- build/s2, on their own branches; `prepare` runs in the main checkout
    -- before the commit.
    local function repo_with_streams(prefix, prepare)
        local main = make_temp_dir(prefix)
        local out, code = run_cmd(string.format(
            "cd %s && git init -q -b main && echo build/ > .gitignore && echo code > app.c && %s && " ..
            "git add . && git commit -q -m init && " ..
            "git worktree add -q -b stream/s1 build/s1 && git worktree add -q -b stream/s2 build/s2",
            main, prepare or "true"))
        return main, code == 0, out
    end

    -- Start every command at once, each from its own directory, and wait
    -- for all of them.
    local function run_concurrently(jobs)
        local parts = {}
        for _, job in ipairs(jobs) do
            parts[#parts + 1] = string.format("(cd %s && %s) &", job[1], job[2])
        end
        return run_cmd("( " .. table.concat(parts, " ") .. " wait )")
    end

    do
        local group = "nested_worktree"
        local main, ok, setup_out = repo_with_streams("tmconfig_nested")
        local s1, s2 = main .. "/build/s1", main .. "/build/s2"
        local active = main .. "/.tasks/active.tm.md"
        local out, code = run_cmd(string.format("cd %s && %s init --orphan", main, tm))
        check(group, "fixture: one commit, tm init --orphan, worktrees build/s1 and build/s2",
            ok and code == 0, setup_out .. out)
        local s1_files = run_cmd("ls -A " .. s1)

        out, code = run_cmd(string.format("cd %s && %s add 'Stream one task'", s1, tm))
        check(group, "tm add from build/s1 adds to the main checkout's active file",
            code == 0 and pending(read_file(active) or "") == 1, out)

        out, code = run_cmd(string.format("cd %s && %s list", s1, tm))
        check(group, "tm list from build/s1 lists the main checkout's tasks",
            code == 0 and out:find("Stream one task", 1, true) ~= nil, out)

        out, code = run_cmd(string.format("cd %s && %s next", s1, tm))
        check(group, "tm next from build/s1 picks from the main checkout's tasks",
            code == 0 and out:find("Stream one task", 1, true) ~= nil, out)

        out, code = run_cmd(string.format("cd %s && %s validate", s1, tm))
        check(group, "tm validate from build/s1 validates the main checkout's active file",
            code == 0 and out:find("/.tasks/active.tm.md", 1, true) ~= nil
                and out:find("/build/", 1, true) == nil, out)

        out, code = run_cmd(string.format("cd %s && %s done 'Stream one task'", s1, tm))
        local body = read_file(active) or ""
        check(group, "tm done from build/s1 completes the task in the main checkout",
            code == 0 and completed(body) == 1 and pending(body) == 0, out)

        check(group, "tm add and tm done create nothing under build/s1",
            run_cmd("ls -A " .. s1) == s1_files and run_cmd("git -C " .. s1 .. " status --porcelain") == "",
            run_cmd("ls -A " .. s1))

        out, code = run_cmd(string.format("cd %s && %s sync -m 'tasks: from stream one'", s1, tm))
        local tasks_subject = run_cmd("git -C " .. main .. " log -1 --format=%s tasks")
        local stream_commits = run_cmd("git -C " .. main .. " rev-list --count stream/s1")
        check(group, "tm sync from build/s1 commits to the tasks branch",
            code == 0 and tasks_subject:match("^tasks: from stream one") ~= nil, out .. tasks_subject)
        check(group, "tm sync from build/s1 commits nothing to the stream branch",
            stream_commits:match("^1%s*$") ~= nil, stream_commits)

        -- Concurrent writers from both worktrees.
        run_cmd(string.format("cd %s && %s add 'Finish while others add'", s2, tm))
        local jobs = { { s2, tm .. " done 'Finish while others add'" } }
        for i = 1, 3 do
            jobs[#jobs + 1] = { s1, string.format("%s add 'Concurrent s1 task %d'", tm, i) }
            jobs[#jobs + 1] = { s2, string.format("%s add 'Concurrent s2 task %d'", tm, i) }
        end
        out = run_concurrently(jobs)
        body = read_file(active) or ""
        check(group, "concurrent tm add and tm done from build/s1 and build/s2 all land",
            pending(body) == 6 and completed(body) == 2
                and count(body, "%- %[ %] Concurrent s1 task") == 3
                and count(body, "%- %[ %] Concurrent s2 task") == 3
                and count(body, "%- %[x%] Finish while others add") == 1, out .. body)
        out, code = run_cmd(string.format("cd %s && %s validate", s1, tm))
        check(group, "active file passes tm validate after concurrent writers", code == 0, out)

        -- These check that both worktrees reach the same tasks worktree and
        -- that nothing is dropped; they do not guard tm sync's staging lock.
        out = run_concurrently({ { s1, tm .. " sync -m 'tasks: s1'" }, { s2, tm .. " sync -m 'tasks: s2'" } })
        local status = run_cmd("git -C " .. main .. "/.tasks status --porcelain")
        local committed = run_cmd("git -C " .. main .. " show tasks:active.tm.md")
        check(group, "two concurrent tm sync leave the tasks worktree clean", status == "", out .. status)
        check(group, "two concurrent tm sync commit every concurrent change", committed == body, committed)

        os.execute("rm -rf " .. main)
    end

    do
        local group = "nested_worktree_claim"
        local main, ok, setup_out = repo_with_streams("tmconfig_nested_claim")
        local s1, s2 = main .. "/build/s1", main .. "/build/s2"
        local active = main .. "/.tasks/active.tm.md"
        local out, code = run_cmd(string.format("cd %s && %s init --orphan", main, tm))
        check(group, "fixture: init --orphan with build/s1 and build/s2", ok and code == 0, setup_out .. out)
        local s1_files, s2_files = run_cmd("ls -A " .. s1), run_cmd("ls -A " .. s2)

        run_cmd(string.format("cd %s && %s add 'Claimable task A'", main, tm))
        run_cmd(string.format("cd %s && %s add 'Claimable task B'", main, tm))

        local out1_file, out2_file = main .. "/s1.out", main .. "/s2.out"
        run_concurrently({
            { s1, string.format("%s next --claim > %s 2>&1", tm, out1_file) },
            { s2, string.format("%s next --claim > %s 2>&1", tm, out2_file) },
        })
        local h1 = (read_file(out1_file) or ""):match("^%[(%S+)%]")
        local h2 = (read_file(out2_file) or ""):match("^%[(%S+)%]")
        check(group, "concurrent next --claim from build/s1 and build/s2 prints two different tasks",
            h1 ~= nil and h2 ~= nil and h1 ~= h2,
            string.format("s1=%s s2=%s", tostring(read_file(out1_file)), tostring(read_file(out2_file))))

        local body = read_file(active) or ""
        local today = os.date("%Y-%m-%d")
        local function task_block(id)
            return body:match("(%- %[ %] [^\n]*id:" .. id .. "\n    > %*%*Claimed:%*%* [^\n]+)")
        end
        local b1, b2 = task_block(h1), task_block(h2)
        check(group, "each session's task in main active.tm.md carries its own worktree branch",
            b1 ~= nil and b1:find("> **Claimed:** " .. today .. " stream/s1", 1, true) ~= nil
                and b2 ~= nil and b2:find("> **Claimed:** " .. today .. " stream/s2", 1, true) ~= nil, body)
        check(group, "nothing is created under either worktree",
            run_cmd("ls -A " .. s1) == s1_files and run_cmd("ls -A " .. s2) == s2_files,
            run_cmd("ls -A " .. s1) .. " | " .. run_cmd("ls -A " .. s2))

        out, code = run_cmd(string.format("cd %s && %s done %s", s1, tm, h1))
        body = read_file(active) or ""
        check(group, "tm done from build/s1 clears only its own task's claim",
            code == 0
                and not body:find("> **Claimed:** " .. today .. " stream/s1", 1, true)
                and body:find("> **Claimed:** " .. today .. " stream/s2", 1, true) ~= nil, out .. "\n" .. body)

        out, code = run_cmd(string.format("cd %s && %s sync -m 'tasks: claims'", s2, tm))
        local status = run_cmd("git -C " .. main .. "/.tasks status --porcelain")
        local committed = run_cmd("git -C " .. main .. " show tasks:active.tm.md")
        check(group, "tm sync commits the claims to the tasks branch and leaves tasks worktree clean",
            code == 0 and status == "" and committed == body, out .. status)

        os.execute("rm -rf " .. main)
    end

    -- Tracked layout: the task files are committed on the code branch, so
    -- each worktree checks out its own .taskmarkrc and task files, and tm
    -- uses those. It reaches for the main checkout's only when the
    -- worktree has no such directory (the orphan cases below).
    do
        local group = "nested_worktree_tracked"
        local main, ok, setup_out = repo_with_streams("tmconfig_nested_tracked",
            "echo 'tasks_dir: doc/tasks' > .taskmarkrc && mkdir -p doc/tasks && " ..
            "echo '# Current Sprint' > doc/tasks/active.tm.md")
        local s1 = main .. "/build/s1"
        local main_active = main .. "/doc/tasks/active.tm.md"
        local s1_active = s1 .. "/doc/tasks/active.tm.md"
        check(group, "fixture: committed .taskmarkrc with tasks_dir: doc/tasks", ok, setup_out)

        local out, code = run_cmd(string.format("cd %s && %s add 'Tracked stream task'", s1, tm))
        check(group, "tm add from build/s1 writes the worktree's own doc/tasks",
            code == 0 and (read_file(s1_active) or ""):find("Tracked stream task", 1, true) ~= nil, out)
        check(group, "tm add from build/s1 leaves the main checkout's doc/tasks alone",
            pending(read_file(main_active) or "") == 0, read_file(main_active))

        out, code = run_cmd(string.format("cd %s && %s add --tasks-dir %s/doc/tasks 'Tracked main task'", s1, tm, main))
        check(group, "--tasks-dir <main>/doc/tasks from build/s1 reaches the main checkout's",
            code == 0 and (read_file(main_active) or ""):find("Tracked main task", 1, true) ~= nil
                and (read_file(s1_active) or ""):find("Tracked main task", 1, true) == nil, out)

        os.execute("rm -rf " .. main)
    end

    -- Orphan layout with a committed .taskmarkrc: every worktree checks the
    -- file out, but the task directory it names is ignored on the code
    -- branch and mounted only in the main checkout, so tm must use that one.
    local function orphan_case(group, prepare, init, tasks_dir)
        local main, ok, setup_out = repo_with_streams("tmconfig_" .. group, prepare)
        local s1 = main .. "/build/s1"
        local active = main .. "/" .. tasks_dir .. "/active.tm.md"
        local out, code = run_cmd(string.format("cd %s && %s", main, init))
        check(group, "fixture: committed .taskmarkrc, " .. tasks_dir .. " mounted in the main checkout only",
            ok and code == 0 and read_file(s1 .. "/.taskmarkrc") ~= nil, setup_out .. out)
        local s1_files = run_cmd("ls -A " .. s1)

        out, code = run_cmd(string.format("cd %s && %s add 'Orphan stream task'", s1, tm))
        check(group, "tm add from build/s1 adds to the main checkout's " .. tasks_dir,
            code == 0 and pending(read_file(active) or "") == 1, out)

        run_cmd("mkdir -p " .. s1 .. "/src/deep")
        out, code = run_cmd(string.format("cd %s/src/deep && %s list", s1, tm))
        check(group, "tm list from build/s1/src/deep lists the main checkout's tasks",
            code == 0 and out:find("Orphan stream task", 1, true) ~= nil, out)
        run_cmd("rm -rf " .. s1 .. "/src")

        check(group, "tm add creates nothing under build/s1", run_cmd("ls -A " .. s1) == s1_files,
            run_cmd("ls -A " .. s1))

        os.execute("rm -rf " .. main)
    end

    orphan_case("nested_worktree_orphan_rc",
        "echo 'tasks_dir: doc/tasks' > .taskmarkrc && echo doc/tasks/ >> .gitignore",
        "git worktree add -q --detach --no-checkout doc/tasks && " ..
            "git -C doc/tasks checkout -q --orphan tasks && echo '# Current Sprint' > doc/tasks/active.tm.md",
        "doc/tasks")

    -- The same when .taskmarkrc sets other keys and leaves tasks_dir at its default.
    orphan_case("nested_worktree_orphan_default",
        "echo 'archive_dir: old' > .taskmarkrc", tm .. " init --orphan", ".tasks")
end

-- ── Summary ─────────────────────────────────────────────────────────────

print(string.format("Results: %d passed, %d failed, %d total", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
