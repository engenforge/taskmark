#!/usr/bin/env lua
-- tmsync — commit taskmark changes to the orphan branch
-- Exposed as the `sync` subcommand of the `tm` tool, and runnable directly:
--   tmsync [-m MSG] [--tasks-dir DIR] [-p]
--   tmsync -h | --help

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local tmconfig = require("tmconfig")
local tmio = require("tmio")
local tmgit = require("tmgit")

local USAGE = [=[
tm sync — commit taskmark changes to the orphan branch

Usage:
  tm sync [options]
  tm sync -h | --help

Options:
  -m, --message MSG   Commit message (default: "tasks: sync (<timestamp>)")
  --tasks-dir DIR     Directory holding the task files (default: .tasks, or
                      tasks_dir set in .taskmarkrc -- see SPEC-TASKMARK-05 §9)
  -p, --push          Push after committing (the first push sets the
                      upstream to origin, or to the only remote)

The tasks directory must be the top level of its own git work tree --
normally the orphan-branch worktree made by `tm init --orphan` -- so that
nothing outside it can be staged. Git hooks run as for any commit.
  -h, --help          Show this help
]=]

local die = tmio.die

local function M_run(args)
    args = args or arg or {}

    local tasks_dir
    local message
    local push = false
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--tasks-dir" then
            i = i + 1
            tasks_dir = args[i]
            if not tasks_dir then die("--tasks-dir requires an argument") end
        elseif a == "-m" or a == "--message" then
            i = i + 1
            message = args[i]
            if not message then die(a .. " requires an argument") end
        elseif a:match("^%-%-message=(.*)$") then
            message = a:match("^%-%-message=(.*)$")
        elseif a == "-p" or a == "--push" then
            push = true
        elseif a == "-h" or a == "--help" then
            io.write(USAGE)
            os.exit(0)
        elseif a:match("^%-") then
            die("Unknown option: " .. a .. "\nRun 'tm sync -h' for usage.")
        else
            die("Unexpected argument: " .. a .. "\nRun 'tm sync -h' for usage.")
        end
        i = i + 1
    end

    local cfg = tmconfig.resolve({ tasks_dir = tasks_dir })
    local dir = cfg.tasks_dir

    if not tmio.dir_exists(dir) then
        die("tasks directory does not exist: " .. dir)
    end
    if not tmgit.toplevel(dir) then
        die("tasks directory '" .. dir .. "' is not a git worktree or repository")
    end
    if not tmgit.is_own_toplevel(dir) then
        die(string.format("tasks directory '%s' is not the top level of its own git work tree " ..
            "(it is inside %s); tm sync would stage files outside it. Mount it as a worktree " ..
            "with `tm init --orphan`, or commit it with git directly.", dir, tmgit.toplevel(dir)))
    end
    local branch = tmgit.branch(dir)
    if not branch then die("tasks directory '" .. dir .. "' is on a detached HEAD; check out a branch first") end

    -- The lock covers only staging, so the snapshot never interleaves with
    -- another tm write. It is released before `git commit`, because hooks
    -- may themselves run tm commands that take it (`tm validate --fix`).
    tmio.with_lock(dir, function()
        -- Keep tm's transient lock directory out of commits.
        if not tmio.file_exists(dir .. "/.gitignore") then
            local ok_w, werr = tmio.write_file_atomic(dir .. "/.gitignore", "/" .. tmio.LOCK_NAME .. "/\n")
            if not ok_w then die(werr) end
        end
        local ok, out = tmgit.run(dir, "add", "-A", "--", ".")
        if not ok then die(out) end
    end)

    do
        local ok, out
        local _, staged = tmgit.run(dir, "diff", "--cached", "--name-only")
        if staged == "" then
            print(string.format("Nothing to sync in %s (working tree clean)", dir))
        else
            local msg = (message and message ~= "") and message
                or string.format("tasks: sync (%s)", os.date("%Y-%m-%d %H:%M:%S"))
            ok, out = tmgit.run(dir, "commit", "-q", "-m", msg)
            if not ok then die((out ~= "" and out .. "\n" or "") .. "tm sync: commit failed in " .. dir) end
            print(string.format("Synced %s [%s %s]", dir, branch, tmgit.value(dir, "rev-parse", "--short", "HEAD") or "?"))
        end

        if push then
            if tmgit.value(dir, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}") then
                ok, out = tmgit.run(dir, "push", "-q")
            else
                local remotes = tmgit.remotes(dir)
                local remote
                for _, r in ipairs(remotes) do if r == "origin" then remote = r end end
                if not remote and #remotes == 1 then remote = remotes[1] end
                if not remote then
                    die(#remotes == 0 and "no git remote to push to" or
                        ("several remotes and no upstream; push once with `git -C " .. dir ..
                         " push -u <remote> " .. branch .. "`"))
                end
                ok, out = tmgit.run(dir, "push", "-q", "-u", remote, branch)
            end
            if not ok then die((out ~= "" and out .. "\n" or "") .. "tm sync: push failed from " .. dir) end
            print(string.format("Pushed %s (%s)", dir, branch))
        end
    end

    os.exit(0)
end

local M = { run = M_run }

if arg and arg[0] and arg[0]:match("tmsync%.lua$") then
    M.run()
end

return M
