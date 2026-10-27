#!/usr/bin/env lua
-- tmsweep — SPEC-TASKMARK-03 §5.3-§5.5 task-level sweep, sprint rotation,
-- and archive aging.
-- Exposed as the `sweep`, `rotate`, and `archive` subcommands of the `tm`
-- tool, and also runnable directly:
--   tmsweep [--sweep] [--rotate --sprint VALUE] [--archive] [--dry-run]
--           [--tasks-dir DIR] [active.tm.md [completed.tm.md]]
--   tmsweep -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local core     = require("tmsweep_core")
local tmconfig = require("tmconfig")
local tmscan   = require("tmscan")
local tmmeta   = require("tmmeta")
local tmio     = require("tmio")

local USAGE = [=[
tmsweep — SPEC-TASKMARK-03 §5.3-§5.5 sweep, rotation, and archive

Usage:
  tmsweep [--sweep] [--rotate --sprint VALUE] [--archive] [--dry-run]
          [--tasks-dir DIR] [active.tm.md [completed.tm.md]]
  tmsweep -h | --help

  Manage task lifecycle across doc/tasks/ documents:

  --sweep      Move every `- [x]` task and its payload out of active.tm.md
               into completed.tm.md. Headings and top-level prose are never
               swept, even when every task beneath them is done.

  --rotate     A sweep, then update `sprint` and `date` in active.tm.md's
               frontmatter and `date` in completed.tm.md's. Requires
               --sprint. future.tm.md is never read or touched, and no
               task is ever promoted automatically.

  --archive    Move sections aged out of completed.tm.md into
               archive/<YYYY>/<YYYY-MM>.tm.md, grouped by the month of each
               section's most recent Completed task. A section is retained
               if it is among the 10 newest or its most recent Completed
               task is dated within the last 14 days.

  Any combination may be given together; sweep/rotate run before archiving.

Options:
  --sweep       Sweep completed tasks from active.tm.md to completed.tm.md
  --rotate      Sweep, then bump frontmatter (requires --sprint)
  --sprint VAL  New sprint identifier to stamp on active.tm.md; required
                with --rotate
  --archive     Archive aged-out sections from completed.tm.md to archive/
  --dry-run     Report what would move and change nothing
  --tasks-dir   Directory holding the task files (default: doc/tasks, or
                the tasks_dir set in .taskmarkrc -- see SPEC-TASKMARK-03 §10)
  -h, --help    Show this help
]=]

local function read_file_content(path)
    local f = io.open(path, "r")
    if not f then return nil, nil end
    local content = f:read("*a")
    f:close()
    local nl = tmscan.detect_newline(content)
    local lines = tmscan.lines_of(content)
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

-- The `sprint:` value currently in active_lines' frontmatter, or nil.
local function current_sprint(active_lines)
    local tbl = tmmeta.split_frontmatter(active_lines)
    return tbl and tbl.sprint
end

-- Entry point. `args` defaults to the global arg table so the script may be
-- run directly; when required by `tm`, it is called with an explicit table.
local function M_run(args)
    args = args or arg

    local sweep_flag, rotate_flag, archive_flag, dry_run, tasks_dir, sprint_value
    local positionals = {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--sweep" then
            sweep_flag = true
        elseif a == "--rotate" then
            rotate_flag = true
        elseif a == "--sprint" then
            i = i + 1
            sprint_value = args[i]
            if not sprint_value then die("--sprint requires an argument") end
        elseif a == "--archive" then
            archive_flag = true
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

    if not (sweep_flag or rotate_flag or archive_flag) then
        io.stderr:write("No action given. Run 'tmsweep -h' for usage.\n")
        os.exit(1)
    end
    if rotate_flag and not sprint_value then
        die("--rotate requires --sprint VALUE")
    end

    -- Resolve file paths. A positional active.tm.md (and optional
    -- completed.tm.md) wins; otherwise derive both from --tasks-dir /
    -- .taskmarkrc / the built-in doc/tasks default (SPEC-TASKMARK-03 §10).
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

    -- Sweep (optionally as part of rotate): move completed tasks from
    -- active into completed, grouped under the active file's current
    -- sprint. Returns true if anything moved.
    local function do_sweep_or_rotate()
        local active_lines, active_nl = read_file_content(active_path)
        if not active_lines then die("no such file: " .. active_path) end
        if not file_exists(completed_path) then
            die("no such file: " .. completed_path ..
                " (nothing to sweep into; create it or run against an explicit path)")
        end
        local completed_lines, completed_nl = read_file_content(completed_path)
        if not completed_lines then die("no such file: " .. completed_path) end

        -- A rotate proceeds (to bump frontmatter) even when there is
        -- nothing to sweep; a bare sweep with nothing to move is a no-op.
        local new_active, moved = core.sweep(active_lines)
        local swept_anything = new_active ~= nil
        if not swept_anything then
            if not rotate_flag then
                if dry_run then info("No completed tasks to sweep.") end
                return false
            end
            new_active = active_lines
        end

        local new_completed = completed_lines
        local descriptions = {}
        if swept_anything then
            local sprint_label = current_sprint(active_lines)
            new_completed = core.insert_into_completed(completed_lines, moved, sprint_label)
            for _, mb in ipairs(moved) do
                local _, fields = tmscan.classify(mb.lines[1])
                descriptions[#descriptions + 1] = fields.description
            end
        end

        if rotate_flag then
            local today = os.date("%Y-%m-%d")
            new_active = core.bump_frontmatter_sprint(new_active, sprint_value)
            new_active = core.bump_frontmatter_date(new_active, today)
            new_completed = core.bump_frontmatter_date(new_completed, today)
        end

        new_active = core.normalize_blank_lines(new_active)
        new_completed = core.normalize_blank_lines(new_completed)

        if dry_run then
            for _, d in ipairs(descriptions) do
                info(string.format('Would sweep: "%s"', d))
            end
            if rotate_flag then
                info(string.format("Would set sprint: %s", sprint_value))
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
        if rotate_flag then
            info(string.format("Rotated %s: sprint set to %s", active_path, sprint_value))
        end
        return true
    end

    local function do_archive()
        local completed_lines, completed_nl = read_file_content(completed_path)
        if not completed_lines then die("no such file: " .. completed_path) end

        local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
        local today = now:match("^(%d%d%d%d%-%d%d%-%d%d)") or os.date("%Y-%m-%d")

        local new_completed_lines, archive_groups = core.cap_completed(completed_lines, {
            now = now,
        })

        if not new_completed_lines or not archive_groups or #archive_groups == 0 then
            if dry_run then info("No sections old enough to archive.") end
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

        if dry_run then
            for _, item in ipairs(archived) do
                info(string.format('Would archive sprint: "%s" -> %s', item.title, item.dest))
            end
            info(string.format("%d section(s) would archive; no files changed.", #archived))
            return
        end

        -- Write archive files first before modifying completed.tm.md:
        -- archive files are the destination of record, so if any archive
        -- write fails, completed.tm.md must be left untouched rather than
        -- having already lost the sections.
        for _, group in ipairs(archive_groups) do
            local year_dir = tasks_dir_resolved .. "/" .. cfg.archive_dir .. "/" .. group.year
            mkdir_p(year_dir)
            local archive_path = year_dir .. "/" .. group.year .. "-" .. group.month .. ".tm.md"
            local archive_lines, archive_nl = read_file_content(archive_path)
            local write_nl = archive_nl or completed_nl or "\n"
            if not archive_lines then
                local proj = core.frontmatter_project(completed_lines) or "tasks"
                local fm = tmmeta.render({
                    project = proj,
                    status  = "Archive",
                    date    = today,
                }, { "project", "status", "date" })
                archive_lines = { "---" }
                for _, l in ipairs(fm) do archive_lines[#archive_lines + 1] = l end
                archive_lines[#archive_lines + 1] = "---"
                archive_lines[#archive_lines + 1] = ""
                archive_lines[#archive_lines + 1] =
                    string.format("# Archived Tasks — %s-%s", group.year, group.month)
            end
            -- Archive files are append-only and never rewritten: existing
            -- content, including its frontmatter date, is untouched -- only
            -- the newly-appended tail is written.
            archive_lines = core.append_blocks(archive_lines, group.blocks)
            local ok, err = write_lines_atomic(archive_path, archive_lines, write_nl)
            if not ok then die(err) end
        end

        local ok, err = write_lines_atomic(completed_path, new_completed_lines, completed_nl)
        if not ok then die(err) end

        for _, item in ipairs(archived) do
            info(string.format('Archived sprint: "%s" -> %s', item.title, item.dest))
        end
    end

    if sweep_flag or rotate_flag then do_sweep_or_rotate() end
    if archive_flag then do_archive() end

    os.exit(0)
end

local M = { run = M_run }

-- When invoked directly (not required as a module), run immediately.
if arg and arg[0] and arg[0]:match("tmsweep%.lua$") then
    M.run()
end

return M
