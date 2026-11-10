#!/usr/bin/env lua
-- tmgit.lua — the few git operations `tm init --orphan` and `tm sync` need.
-- Every argument is shell-quoted, git's own output is captured so failures
-- can be reported verbatim, and hooks run normally: nothing here passes
-- --no-verify or otherwise steps around the user's git configuration.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. package.path
local tmio = require("tmio")

local M = {}

-- Run `git [-C dir] args...`. Returns ok, output (stdout and stderr,
-- trailing whitespace trimmed).
function M.run(dir, ...)
    local parts = { "git" }
    if dir then parts[#parts + 1] = "-C " .. tmio.shell_quote(dir) end
    for _, a in ipairs({ ... }) do parts[#parts + 1] = tmio.shell_quote(a) end
    local p = io.popen(table.concat(parts, " ") .. " 2>&1; echo \"__TM_EXIT__$?\"")
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("__TM_EXIT__(%d+)%s*$")) or 1
    out = out:gsub("__TM_EXIT__%d+%s*$", ""):gsub("%s+$", "")
    return code == 0, out
end

-- Like run, but returns only the output on success, else nil.
function M.value(dir, ...)
    local ok, out = M.run(dir, ...)
    if ok and out ~= "" then return out end
    return nil
end

-- Absolute, symlink-resolved form of an existing directory.
M.realpath = tmio.realpath

-- Top level of the work tree containing `dir` (nil if not in one).
function M.toplevel(dir)
    return M.value(dir, "rev-parse", "--show-toplevel")
end

-- True when `dir` is the top level of its own work tree, so that `git -C dir
-- add -A` can only ever stage files under `dir`. A plain directory inside
-- some larger repository is not.
function M.is_own_toplevel(dir)
    local top, real = M.toplevel(dir), M.realpath(dir)
    return top ~= nil and real ~= nil and M.realpath(top) == real
end

-- True when `dir` is the top level of a *linked* worktree (one created by
-- `git worktree add`), as opposed to a repository's main checkout: a linked
-- worktree's `.git` is a file pointing into the main repository, a main
-- checkout's is a directory. (Works on any git, unlike --path-format.)
function M.is_linked_worktree(dir)
    return M.is_own_toplevel(dir) and tmio.file_exists(dir .. "/.git")
        and not tmio.dir_exists(dir .. "/.git")
end

-- Current branch of the work tree at `dir` (also for an unborn branch), or
-- nil when HEAD is detached.
function M.branch(dir)
    return M.value(dir, "symbolic-ref", "--quiet", "--short", "HEAD")
end

function M.ref_exists(dir, ref)
    return (M.run(dir, "show-ref", "--verify", "--quiet", ref))
end

-- Remotes that have a branch named `branch`, from already-fetched refs.
function M.remotes_with_branch(dir, branch)
    local out = M.value(dir, "for-each-ref", "--format=%(refname)", "refs/remotes/") or ""
    local found = {}
    for ref in out:gmatch("[^\n]+") do
        local remote = ref:match("^refs/remotes/(.+)/" .. branch:gsub("%p", "%%%0") .. "$")
        if remote then found[#found + 1] = remote end
    end
    return found
end

function M.remotes(dir)
    local out = M.value(dir, "remote") or ""
    local list = {}
    for r in out:gmatch("[^\n]+") do list[#list + 1] = r end
    return list
end

return M
