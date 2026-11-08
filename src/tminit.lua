#!/usr/bin/env lua
-- tminit — SPEC-TASKMARK-04 taskmark directory initialization.
-- Exposed as the `init` subcommand of the `tm` tool, and also runnable directly:
--   tminit [--tasks-dir DIR]
--   tminit -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local tmconfig = require("tmconfig")
local tmio = require("tmio")

local USAGE = [=[
tm init — SPEC-TASKMARK-04 taskmark project initialization

Usage:
  tm init [--tasks-dir DIR]
  tm init -h | --help

Options:
  --tasks-dir DIR  Directory to scaffold (default: .tasks, or the
                   tasks_dir set in .taskmarkrc -- see SPEC-TASKMARK-04 §9)
  -h, --help       Show this help
]=]

local die = tmio.die

-- Build a starter file's content: pure CommonMark section heading and trailing newline.
local function starter(heading)
    return heading .. "\n"
end

local function templates(cfg)
    return {
        {
            name = cfg.active_file,
            content = starter("# Current Sprint"),
        },
        {
            name = cfg.future_file,
            content = starter("# Planned Work"),
        },
        {
            name = cfg.completed_file,
            content = starter("# Completed Archive"),
        },
    }
end

local function M_run(args)
    args = args or arg or {}

    local tasks_dir
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--tasks-dir" then
            i = i + 1
            tasks_dir = args[i]
            if not tasks_dir then die("--tasks-dir requires an argument") end
        elseif a == "-h" or a == "--help" then
            io.write(USAGE)
            os.exit(0)
        elseif a:match("^%-") then
            die("Unknown option: " .. a .. "\nRun 'tm init -h' for usage.")
        else
            die("Unexpected argument: " .. a .. "\nRun 'tm init -h' for usage.")
        end
        i = i + 1
    end

    local cfg = tmconfig.resolve({ tasks_dir = tasks_dir })
    local dir = cfg.tasks_dir
    local tmpls = templates(cfg)

    for _, tmpl in ipairs(tmpls) do
        local path = dir .. "/" .. tmpl.name
        if tmio.file_exists(path) then
            print(string.format("Skipped %s (already exists)", path))
        else
            if not tmio.mkdir_p(dir) then die("cannot create directory: " .. dir) end
            local ok, err = tmio.write_file_atomic(path, tmpl.content)
            if not ok then die(err) end
            print(string.format("Created %s", path))
        end
    end

    os.exit(0)
end

local M = { run = M_run }

if arg and arg[0] and arg[0]:match("tminit%.lua$") then
    M.run()
end

return M
