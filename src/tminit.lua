#!/usr/bin/env lua
-- tminit — SPEC-TASKMARK-04 taskmark directory initialization.
-- Exposed as the `init` subcommand of the `tm` tool, and also runnable directly:
--   tminit [--orphan [BRANCH]] [--tasks-dir DIR]
--   tminit -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local tmconfig = require("tmconfig")
local tmio = require("tmio")
local tmgit = require("tmgit")

local USAGE = [=[
tm init — SPEC-TASKMARK-04 taskmark project initialization

Usage:
  tm init [--orphan [BRANCH]] [--tasks-dir DIR]
  tm init -h | --help

Options:
  --orphan [BRANCH] From the repository root: mount BRANCH (default: tasks)
                   at the tasks directory as a git worktree -- an existing
                   local or fetched remote branch if there is one, else a
                   new orphan branch -- add the directory to .gitignore
                   (and, if it is not .tasks, set tasks_dir in .taskmarkrc)
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

-- ── tm init --orphan ──────────────────────────────────────────────────────

-- Append `entry` as its own line to root/<name> unless an equivalent line
-- (per `same(line)`) is already there. Returns changed?, or nil, reason.
local function ensure_line(path, entry, same)
    local content = ""
    local f = io.open(path, "r")
    if f then content = f:read("*a"); f:close() end
    for line in content:gmatch("[^\r\n]+") do
        if same(line) then return false end
    end
    local sep = (content ~= "" and not content:match("\n$")) and "\n" or ""
    local out = io.open(path, "a")
    if not out then return nil, "cannot write " .. path end
    out:write(sep .. entry .. "\n")
    out:close()
    return true
end

local function ignores_dir(dir)
    return function(line)
        local t = line:match("^%s*(.-)%s*$")
        return t == dir or t == "/" .. dir or t == dir .. "/" or t == "/" .. dir .. "/"
    end
end

-- Mount `branch` at `dir` (relative to the repository root, which is the
-- current directory). In order of preference: an existing local branch; a
-- branch already fetched from a remote (tracked, so a collaborator joins
-- the shared history instead of starting an unrelated one); otherwise a new
-- orphan branch. The new-branch path uses only long-standing git commands
-- (no `worktree add --orphan`, which needs git >= 2.42), and the worktree
-- starts empty -- nothing from the code branch is ever checked out into it.
-- Returns "existing" | "remote" | "new", or nil, reason.
local function mount_worktree(dir, branch)
    if tmio.dir_exists(dir) then
        if tmgit.is_linked_worktree(dir) then
            local cur = tmgit.branch(dir)
            if cur ~= branch then
                return nil, string.format("%s is already a worktree, but on '%s', not '%s'", dir, tostring(cur), branch)
            end
            print(string.format("Worktree %s is already mounted on branch '%s'", dir, branch))
            return "mounted"
        end
        return nil, string.format("'%s' already exists and is not a git worktree; " ..
            "move it aside (or remove it if empty) and rerun", dir)
    end

    if not tmgit.run(nil, "check-ref-format", "--branch", branch) then
        return nil, "not a valid branch name: " .. branch
    end

    local ok, out
    if tmgit.ref_exists(nil, "refs/heads/" .. branch) then
        ok, out = tmgit.run(nil, "worktree", "add", dir, branch)
        if not ok then return nil, out end
        print(string.format("Mounted existing branch '%s' at %s", branch, dir))
        return "existing"
    end

    local remotes = tmgit.remotes_with_branch(nil, branch)
    if #remotes > 0 then
        local remote
        for _, r in ipairs(remotes) do if r == "origin" then remote = r end end
        if not remote and #remotes > 1 then
            return nil, string.format("branch '%s' exists on several remotes (%s); create it with " ..
                "`git branch --track %s <remote>/%s` and rerun", branch, table.concat(remotes, ", "), branch, branch)
        end
        remote = remote or remotes[1]
        ok, out = tmgit.run(nil, "worktree", "add", "--track", "-b", branch, dir, remote .. "/" .. branch)
        if not ok then return nil, out end
        print(string.format("Mounted %s/%s at %s (tracking)", remote, branch, dir))
        return "remote"
    end

    -- New orphan branch: a detached worktree with nothing checked out,
    -- whose HEAD is then pointed at the unborn branch and whose index is
    -- emptied. (`checkout --orphan` would populate the working tree from
    -- the code branch, so it is deliberately not used.)
    ok, out = tmgit.run(nil, "worktree", "add", "--detach", "--no-checkout", dir)
    if ok then ok, out = tmgit.run(dir, "symbolic-ref", "HEAD", "refs/heads/" .. branch) end
    if ok then ok, out = tmgit.run(dir, "read-tree", "--empty") end
    if not ok then
        tmgit.run(nil, "worktree", "remove", "--force", dir)
        return nil, out
    end
    print(string.format("Created orphan branch '%s' at %s", branch, dir))
    return "new"
end

-- First commit on a new orphan branch: only the taskmark files, through a
-- normal `git commit` so the user's hooks run.
local function commit_starter(dir, cfg)
    local paths = { ".gitignore", cfg.active_file, cfg.future_file, cfg.completed_file }
    local ok, out = tmgit.run(dir, "add", "--", (table.unpack or unpack)(paths))
    if ok then ok, out = tmgit.run(dir, "commit", "-q", "-m", "Initialize taskmark task branch") end
    if not ok then
        die(out .. "\n\nThe starter files are in place in " .. dir ..
            " but were not committed; fix the problem above, then run `tm sync`.")
    end
    print(string.format("Committed starter files on '%s'", tmgit.branch(dir) or "?"))
end

local function init_orphan(cfg, branch)
    local root = tmgit.toplevel(".")
    if not root then die("tm init --orphan requires an initialized git repository") end
    if tmgit.realpath(".") ~= tmgit.realpath(root) then
        die("run tm init --orphan from the repository root (" .. root .. "), where .taskmarkrc is read")
    end
    if tmgit.is_linked_worktree(".") then
        die("run tm init --orphan from the repository's main checkout, not a linked worktree")
    end

    local dir = cfg.tasks_dir:gsub("^%./", ""):gsub("/+$", "")
    if dir == "" or dir == "." or dir:match("^/") or dir:match("^%.%.") or dir:match("/%.%.") then
        die("tasks directory must be a path inside the repository: " .. cfg.tasks_dir)
    end

    local how, err = mount_worktree(dir, branch)
    if not how then die(err) end

    local changed = {}
    local c, e = ensure_line(".gitignore", "/" .. dir .. "/", ignores_dir(dir))
    if c == nil then die(e) elseif c then changed[#changed + 1] = ".gitignore" end
    -- .taskmarkrc only records a directory other than the default: tm finds
    -- ".tasks" without it.
    if dir ~= tmconfig.DEFAULTS.tasks_dir then
        c, e = ensure_line(".taskmarkrc", "tasks_dir: " .. dir, function(l) return l:match("^%s*tasks_dir%s*:") ~= nil end)
        if c == nil then die(e) elseif c then changed[#changed + 1] = ".taskmarkrc" end
    end

    -- The worktree's own .gitignore keeps tm's transient lock out of commits.
    if not tmio.file_exists(dir .. "/.gitignore") then
        local ok_w, werr = tmio.write_file_atomic(dir .. "/.gitignore", "/" .. tmio.LOCK_NAME .. "/\n")
        if not ok_w then die(werr) end
    end
    return dir, how, changed
end

local function M_run(args)
    args = args or arg or {}

    local tasks_dir
    local orphan = false
    local orphan_branch = "tasks"
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--tasks-dir" then
            i = i + 1
            tasks_dir = args[i]
            if not tasks_dir then die("--tasks-dir requires an argument") end
        elseif a == "--orphan" then
            orphan = true
            if args[i + 1] and not args[i + 1]:match("^%-") then
                i = i + 1
                orphan_branch = args[i]
            end
        elseif a:match("^%-%-orphan=(.*)$") then
            orphan = true
            local b = a:match("^%-%-orphan=(.*)$")
            if b and b ~= "" then
                orphan_branch = b
            end
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

    local how, changed
    if orphan then
        dir, how, changed = init_orphan(cfg, orphan_branch)
    end

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

    if how == "new" then
        commit_starter(dir, cfg)
    elseif how then
        local status = select(2, tmgit.run(dir, "status", "--porcelain"))
        if status ~= "" then
            print("New starter files in " .. dir .. " are not committed; review them, then run `tm sync`.")
        end
    end
    if changed and #changed > 0 then
        print(string.format("Updated %s on the code branch: commit %s there.",
            table.concat(changed, " and "), #changed > 1 and "them" or "it"))
    end

    os.exit(0)
end

local M = { run = M_run }

if arg and arg[0] and arg[0]:match("tminit%.lua$") then
    M.run()
end

return M
