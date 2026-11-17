#!/usr/bin/env lua
-- tmsweep — SPEC-TASKMARK-06 §5.3-§5.5 task-level sweep and archive aging.
-- Exposed as the `sweep` and `archive` subcommands of the `tm` tool, and
-- also runnable directly:
--   tmsweep [--sweep] [--archive [--max-bytes N]] [--dry-run]
--           [--tasks-dir DIR] [active.tm.md [completed.tm.md]]
--   tmsweep -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local core     = require("tmsweep_core")
local tmconfig = require("tmconfig")
local tmscan   = require("tmscan")
local tmio     = require("tmio")

local USAGE = [=[
tmsweep — SPEC-TASKMARK-06 §5.3-§5.5 sweep and archive

Usage:
  tmsweep [--sweep] [--archive [--max-bytes N]] [--dry-run]
          [--tasks-dir DIR] [active.tm.md [completed.tm.md]]
  tmsweep -h | --help

  Manage task lifecycle across .tasks/ documents:

  --sweep        Move every `- [x]` task and its payload out of active.tm.md
                 into completed.tm.md, newest first, directly beneath its
                 title. Headings and top-level prose are never swept, even
                 when every task beneath them is done.

  --archive      Move tasks aged out of completed.tm.md into
                 archive/<YYYY>/<YYYY-MM>.tm.md, newest first, grouped by
                 the month of each task's Completed date. A task is retained
                 if it is among the 2 newest or its Completed date is within
                 the last 14 days, unless --max-bytes (or archive_max_bytes)
                 is > 0 and completed.tm.md exceeds that size, in which case
                 oldest dated tasks archive first (keeping at least 1 newest
                 task).

  Both may be given together; the sweep runs before archiving.

Options:
  --sweep         Sweep completed tasks from active.tm.md to completed.tm.md
  --archive       Archive aged-out tasks from completed.tm.md to archive/
  --max-bytes N   With --archive: keep completed.tm.md within N bytes (0
                  disables; overrides archive_max_bytes in .taskmarkrc)
  --dry-run       Report what would move and change nothing
  --tasks-dir     Directory holding the task files (default: .tasks, or
                  the tasks_dir set in .taskmarkrc -- see SPEC-TASKMARK-06 §9)
  -h, --help      Show this help
]=]

local function read_file_content(path, warned)
    local f = io.open(path, "r")
    if not f then return nil, nil end
    local content = f:read("*a")
    f:close()
    local nl = tmscan.detect_newline(content)
    local lines = tmscan.lines_of(content)
    tmio.warn_indented_tasks(path, lines, warned)
    return lines, nl
end

-- Write via a temp file and rename, so an interrupted run cannot leave a
-- half-written task document behind. Preserves the document's original newline style.
local function write_lines_atomic(path, lines, nl)
    nl = nl or "\n"
    return tmio.write_file_atomic(path, table.concat(lines, nl) .. nl)
end

local file_exists = tmio.file_exists
local mkdir_p = tmio.mkdir_p
local die = tmio.die

local function info(msg) print(msg) end

-- Entry point. `args` defaults to the global arg table so the script may be
-- run directly; when required by `tm`, it is called with an explicit table.
local function M_run(args)
    args = args or arg

    local sweep_flag, archive_flag, dry_run, tasks_dir, max_bytes_arg
    local positionals = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--sweep" then
            sweep_flag = true
        elseif a == "--archive" then
            archive_flag = true
        elseif a == "--max-bytes" then
            i = i + 1
            local raw = args[i]
            if not raw then die("--max-bytes requires an argument") end
            if not raw:match("^%d+$") then
                die("--max-bytes must be a non-negative integer: " .. raw)
            end
            max_bytes_arg = tonumber(raw)
        elseif a == "--dry-run" then
            dry_run = true
        elseif a == "--tasks-dir" then
            i = i + 1
            tasks_dir = args[i]
            if not tasks_dir then die("--tasks-dir requires an argument") end
        elseif a == "-h" or a == "--help" then
            io.write(USAGE)
            os.exit(0)
        elseif a:match("^%-") then
            die("Unknown option: " .. a .. "\nRun 'tmsweep -h' for usage.")
        else
            table.insert(positionals, a)
        end
        i = i + 1
    end

    if not (sweep_flag or archive_flag) then
        io.stderr:write("No action given. Run 'tmsweep -h' for usage.\n")
        os.exit(1)
    end
    if max_bytes_arg ~= nil and not archive_flag then
        die("--max-bytes applies only to --archive")
    end

    -- Resolve file paths. A positional active.tm.md (and optional
    -- completed.tm.md) wins; otherwise derive both from --tasks-dir /
    -- .taskmarkrc / the built-in .tasks default (SPEC-TASKMARK-06 §9).
    local cfg = tmconfig.resolve({ tasks_dir = tasks_dir })
    local active_path, completed_path
    if #positionals >= 1 then
        active_path = positionals[1]
        completed_path = positionals[2] or active_path:gsub("active%.tm%.md$", "completed.tm.md")
    else
        active_path = cfg.active_path
        completed_path = cfg.completed_path
    end
    local tasks_dir_resolved = completed_path:match("^(.*)/[^/]+$") or "."
    local max_bytes = max_bytes_arg
    if archive_flag and max_bytes == nil then
        local raw = tostring(cfg.archive_max_bytes or "0")
        if not raw:match("^%d+$") then
            die("invalid archive_max_bytes in config (must be a non-negative integer): " .. raw)
        end
        max_bytes = tonumber(raw)
    end

    local warned = {}

    -- Sweep: move completed tasks from active into completed, newest first.
    -- Returns true if anything moved (or would, under --dry-run).
    local function do_sweep()
        local active_lines, active_nl = read_file_content(active_path, warned)
        if not active_lines then die("no such file: " .. active_path) end
        if not file_exists(completed_path) then
            die("no such file: " .. completed_path ..
                " (nothing to sweep into; create it or run against an explicit path)")
        end
        local completed_lines, completed_nl = read_file_content(completed_path, warned)
        if not completed_lines then die("no such file: " .. completed_path) end

        local new_active, moved = core.sweep(active_lines)
        if not new_active then
            if dry_run then info("No completed tasks to sweep.") end
            return false
        end

        local new_completed = core.insert_into_completed(completed_lines, moved)
        local descriptions = {}
        for _, mb in ipairs(moved) do
            local _, fields = tmscan.classify(mb.lines[1])
            descriptions[#descriptions + 1] = fields.description
        end

        new_active = core.normalize_blank_lines(new_active)
        new_completed = core.normalize_blank_lines(new_completed)

        if dry_run then
            for _, d in ipairs(descriptions) do
                info(string.format('Would sweep: "%s"', d))
            end
            info(string.format("%d task(s) would move; no files changed.", #descriptions))
            return true
        end

        -- completed.tm.md first: if the second write fails, the work is
        -- preserved in the archive and the sweep is merely repeated,
        -- whereas the reverse order would drop the tasks out of
        -- active.tm.md with nowhere to land.
        local ok, err = write_lines_atomic(completed_path, new_completed, completed_nl)
        if not ok then die(err) end
        ok, err = write_lines_atomic(active_path, new_active, active_nl)
        if not ok then die(err) end

        for _, d in ipairs(descriptions) do
            info(string.format('Swept: "%s" -> %s', d, completed_path))
        end
        return true
    end

    local function do_archive()
        local completed_lines, completed_nl = read_file_content(completed_path, warned)
        if not completed_lines then die("no such file: " .. completed_path) end

        local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
        local today = now:match("^(%d%d%d%d%-%d%d%-%d%d)") or os.date("%Y-%m-%d")

        local new_completed_lines, archive_groups, cap_info = core.cap_completed(completed_lines, {
            now = now,
            max_bytes = max_bytes,
            nl = completed_nl,
        })

        if not new_completed_lines or not archive_groups or #archive_groups == 0 then
            if cap_info and cap_info.over_cap then
                io.stderr:write(string.format(
                    "warning: %s is %d bytes (exceeds max_bytes=%d; dateless tasks or newest task could not be archived)\n",
                    completed_path, cap_info.bytes, cap_info.max_bytes))
            end
            if dry_run then info("No tasks old enough to archive.") end
            return
        end
        new_completed_lines = core.normalize_blank_lines(new_completed_lines)

        local archived = {}
        for _, group in ipairs(archive_groups) do
            local dest = string.format("%s/%s/%s/%s-%s.tm.md",
                tasks_dir_resolved, cfg.archive_dir, group.year, group.year, group.month)
            for _, block in ipairs(group.blocks) do
                table.insert(archived, { title = block.title, dest = dest })
            end
        end

        if cap_info and cap_info.over_cap then
            io.stderr:write(string.format(
                "warning: %s is %d bytes (exceeds max_bytes=%d; dateless tasks or newest task could not be archived)\n",
                completed_path, cap_info.bytes, cap_info.max_bytes))
        end

        if dry_run then
            for _, item in ipairs(archived) do
                info(string.format('Would archive task: "%s" -> %s', item.title, item.dest))
            end
            info(string.format("%d task(s) would archive; no files changed.", #archived))
            return
        end

        -- Write archive files first before modifying completed.tm.md:
        -- archive files are the destination of record, so if any archive
        -- write fails, completed.tm.md must be left untouched rather than
        -- having already lost the tasks.
        for _, group in ipairs(archive_groups) do
            local year_dir = tasks_dir_resolved .. "/" .. cfg.archive_dir .. "/" .. group.year
            if not mkdir_p(year_dir) then die("cannot create directory: " .. year_dir) end
            local archive_path = year_dir .. "/" .. group.year .. "-" .. group.month .. ".tm.md"
            local archive_lines, archive_nl = read_file_content(archive_path, warned)
            local write_nl = archive_nl or completed_nl or "\n"
            if not archive_lines then
                archive_lines = {
                    string.format("# Archived Tasks — %s-%s", group.year, group.month)
                }
            end
            -- Newest first, beneath the archive title; existing entries
            -- are carried over verbatim.
            archive_lines = core.prepend_blocks(archive_lines, group.blocks)
            local ok, err = write_lines_atomic(archive_path, archive_lines, write_nl)
            if not ok then die(err) end
        end

        local ok, err = write_lines_atomic(completed_path, new_completed_lines, completed_nl)
        if not ok then die(err) end

        for _, item in ipairs(archived) do
            info(string.format('Archived task: "%s" -> %s', item.title, item.dest))
        end
    end

    -- Every action is a read-modify-write of the task directory: hold its
    -- lock throughout so a concurrent tm run cannot interleave and lose an
    -- update (die() releases it on any fatal error).
    tmio.with_lock(tasks_dir_resolved, function()
        if sweep_flag then do_sweep() end
        if archive_flag then do_archive() end
    end)

    os.exit(0)
end

local M = { run = M_run }

-- When invoked directly (not required as a module), run immediately.
if arg and arg[0] and arg[0]:match("tmsweep%.lua$") then
    M.run()
end

return M
