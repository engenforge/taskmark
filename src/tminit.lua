#!/usr/bin/env lua
-- tminit — SPEC-TASKMARK-03 taskmark directory initialization.
-- Exposed as the `init` subcommand of the `tm` tool, and also runnable directly:
--   tminit [--tasks-dir DIR]
--   tminit -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local tmconfig = require("tmconfig")
local tmmeta = require("tmmeta")
local tmio = require("tmio")

local USAGE = [=[
tm init — SPEC-TASKMARK-03 taskmark project initialization

Usage:
  tm init [--tasks-dir DIR]
  tm init -h | --help

Options:
  --tasks-dir DIR  Directory to scaffold (default: doc/tasks, or the
                   tasks_dir set in .taskmarkrc -- see SPEC-TASKMARK-03 §10)
  -h, --help       Show this help
]=]

local die = tmio.die

-- Build a starter file's content: `---` frontmatter via tmmeta.render,
-- keyed in schema order (§2.3), then a blank line and the section heading.
local function starter(fields, heading)
    local order = { "project", "status", "sprint", "date" }
    local lines = { "---" }
    for _, l in ipairs(tmmeta.render(fields, order)) do lines[#lines + 1] = l end
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = heading
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

local function templates(today, cfg)
    return {
        {
            name = cfg.active_file,
            content = starter({ project = "tasks", status = "Active", sprint = os.date("%Y") .. "-S1", date = today },
                "# Current Sprint"),
        },
        {
            name = cfg.future_file,
            content = starter({ project = "tasks", status = "Planned", date = today }, "# Planned Work"),
        },
        {
            name = cfg.completed_file,
            content = starter({ project = "tasks", status = "Archive", date = today }, "# Completed Archive"),
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
    local today = os.date("%Y-%m-%d")
    local tmpls = templates(today, cfg)

    for _, tmpl in ipairs(tmpls) do
        local path = dir .. "/" .. tmpl.name
        if tmio.file_exists(path) then
            print(string.format("Skipped %s (already exists)", path))
        else
            tmio.mkdir_p(dir)
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
