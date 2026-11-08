#!/usr/bin/env lua
-- tests/tminit_test.lua — unit + end-to-end tests for tminit.lua and `tm init`
--
-- Self-contained runner (mirroring tests/tmsweep_test.lua style).

local script_dir = (arg[0] or "./tests/tminit_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

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

-- ── Summary ──────────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
