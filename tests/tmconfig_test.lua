#!/usr/bin/env lua
-- tests/tmconfig_test.lua — unit + end-to-end tests for tmconfig.lua
-- (SPEC-TASKMARK-04 §9 configuration resolution).
--
-- Self-contained runner (mirroring tests/tmsweep_test.lua / tminit_test.lua
-- style).

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
]])

    local cfg = tmconfig.resolve({ config_path = path, global_config_path = NO_GLOBAL })
    check("resolve", "file config: tasks_dir", cfg.tasks_dir == "tracking")
    check("resolve", "file config: active_path", cfg.active_path == "tracking/now.tm.md")
    check("resolve", "file config: future_path", cfg.future_path == "tracking/later.tm.md")
    check("resolve", "file config: completed_path", cfg.completed_path == "tracking/done.tm.md")
    check("resolve", "file config: archive_dir", cfg.archive_dir == "history")

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
    out, code = run_cmd(string.format("cd %s && lua %s sweep --sprint 2026-S2", dir, tm))
    check("e2e", "tm sweep with no positional args resolves configured paths: exit 0", code == 0)
    check("e2e", "tm sweep moved the task into the configured completed file",
          (read_file(dir .. "/tracking/done.tm.md") or ""):match("Finished thing") ~= nil)

    -- Age the swept section out and confirm archive lands under the
    -- configured archive_dir name.
    -- Two recent filler sections plus OLD: OLD must be neither among the 2
    -- newest nor within the 14-day window to actually age out (a lone
    -- section is always "among the 2 newest" and would never move).
    local completed_body = "# Completed Archive\n\n"
    for n = 2, 1, -1 do
        completed_body = completed_body ..
            string.format("## R%d\n- [x] t\n    > **Completed:** 2026-08-2%d\n\n", n, n % 10)
    end
    completed_body = completed_body .. "## OLD\n- [x] old thing\n    > **Completed:** 2026-01-01\n"
    write_file(dir .. "/tracking/done.tm.md", completed_body)

    out, code = run_cmd(string.format("cd %s && lua %s archive", dir, tm))
    check("e2e", "tm archive with no flags/args resolves configured paths: exit 0", code == 0)
    check("e2e", "tm archive uses the configured archive_dir name",
          read_file(dir .. "/tracking/history/2026/2026-01.tm.md") ~= nil)

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

-- ── Summary ─────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
