#!/usr/bin/env lua
-- tmconfig — SPEC-TASKMARK-05 §9 configuration resolution.
--
-- Resolves the on-disk paths tm's subcommands operate on (the .tasks/
-- directory itself, active.tm.md/future.tm.md/completed.tm.md, the archive/
-- subdirectory name) from, per key, in order of
-- precedence:
--   1. Explicit values passed by the caller (typically parsed CLI flags,
--      e.g. --tasks-dir)
--   2. An optional `.taskmarkrc` file in the current working directory
--   3. An optional global `$XDG_CONFIG_HOME/taskmark/config` file (falling
--      back to `~/.config/taskmark/config` when XDG_CONFIG_HOME is unset or
--      empty)
--   4. Built-in conventional defaults
--
-- A missing, unreadable, or malformed config file is never an error --
-- resolution silently falls through to the next layer, so a project with no
-- config file behaves exactly as documented before configuration existed.
-- Both files are parsed with tmmeta's relaxed flat `key: value` reader
-- (§9.1); no serialization dependency of any kind.

local function self_dir()
    local s = (debug.getinfo and debug.getinfo(1, "S").source:match("^@(.*)$")) or (arg and arg[0]) or "."
    return s:match("^(.*)/[^/]+$") or "."
end

do
    local dir = self_dir()
    package.path = dir .. "/?.lua;" .. dir .. "/../share/tm/?.lua;" .. package.path
end

local tmmeta = require("tmmeta")
local tmio   = require("tmio")

local M = {}

-- Conventional paths this spec has always used, unchanged when no
-- configuration is present.
M.DEFAULTS = {
    tasks_dir      = ".tasks",
    active_file    = "active.tm.md",
    future_file    = "future.tm.md",
    completed_file = "completed.tm.md",
    archive_dir    = "archive",
}

M.CONFIG_FILENAME = ".taskmarkrc"

-- The pre-0.4 default task directory. Used only when tasks_dir is not
-- configured anywhere, the default directory does not exist, and this one
-- does -- so an existing project keeps working after upgrading.
M.LEGACY_TASKS_DIR = "doc/tasks"

-- The global config file path: overrides.global_config_path, if given,
-- names an alternate file to load instead (mainly for tests).
function M.global_config_path()
    local xdg = os.getenv("XDG_CONFIG_HOME")
    if xdg and xdg ~= "" then
        return xdg .. "/taskmark/config"
    end
    local home = os.getenv("HOME") or ""
    return home .. "/.config/taskmark/config"
end

-- Read a file's lines (without trailing newlines) into an array, or nil if
-- the file does not exist / cannot be opened.
local function read_lines(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

-- Read and parse a config file (default: M.CONFIG_FILENAME in the current
-- directory). Returns a table holding only the recognized string keys it
-- found; {} if the file is absent, empty, or contains a line the reader
-- rejects -- config loading never fails the caller.
function M.load(path)
    path = path or M.CONFIG_FILENAME
    local lines = read_lines(path)
    if not lines then return {} end

    local ok, parsed = pcall(tmmeta.parse_lines, lines, { relaxed = true })
    if not ok or not parsed then return {} end

    local out = {}
    for key in pairs(M.DEFAULTS) do
        local v = parsed[key]
        if type(v) == "string" and v ~= "" then
            out[key] = v
        end
    end
    return out
end

-- Whether `dir` is the root of a Git repository or worktree that acts as
-- a project boundary (stopping upward config discovery).
-- A standalone repository (.git directory), a submodule (.git file pointing
-- to modules/), or a worktree whose main checkout is NOT an ancestor of `dir`
-- are boundaries. A linked worktree mounted inside its own enclosing repository
-- (.git file pointing to an ancestor's .git/worktrees/) is not a boundary: the
-- upward search continues into the enclosing repository holding .taskmarkrc.
local function is_git_boundary(dir)
    local git_dir = dir .. "/.git"
    if tmio.dir_exists(git_dir) then
        return true
    end
    if tmio.file_exists(git_dir) then
        local f = io.open(git_dir, "r")
        local line = f and f:read("*l") or ""
        if f then f:close() end
        local target = line:match("^gitdir:%s*(.-)%s*$")
        if target then
            if not target:match("^/") then
                target = tmio.realpath(dir .. "/" .. target) or (dir .. "/" .. target)
            end
            local main_repo = target:match("^(.-)/%.git/worktrees/")
            if main_repo then
                main_repo = tmio.realpath(main_repo) or main_repo
                if dir:sub(1, #main_repo + 1) == main_repo .. "/" then
                    return false
                end
            end
        end
        return true
    end
    return false
end

-- Search upward from `start_dir` (default: ".") for `.taskmarkrc`, stopping
-- at the enclosing Git worktree or repository root (where .git exists as a
-- directory or file), or at the filesystem root. Returns:
--   config_path, root_dir
-- where config_path is the path to .taskmarkrc, and root_dir is the directory
-- containing it. If no .taskmarkrc is found, config_path is nil and root_dir
-- is the repository root (if stopped by a .git boundary) or nil.
function M.find_config(start_dir)
    local cur = tmio.realpath(start_dir or ".")
    if not cur then return nil, nil end

    while true do
        local cand = cur .. "/" .. M.CONFIG_FILENAME
        if tmio.file_exists(cand) then
            return cand, cur
        end
        if is_git_boundary(cur) then
            return nil, cur
        end
        if cur == "/" then
            return nil, nil
        end
        local parent = cur:match("^(.*)/[^/]+$")
        if not parent or parent == "" then parent = "/" end
        cur = parent
    end
end

-- Merge explicit `overrides` (e.g. a parsed --tasks-dir; nil fields are
-- skipped) over the local .taskmarkrc over the global config file over the
-- built-in defaults, per key -- not per file -- then derive the file paths
-- tools actually open.
--
-- overrides.config_path, if given, names an alternate local config file to
-- load instead of M.CONFIG_FILENAME; overrides.global_config_path, if
-- given, names an alternate global config file to load instead of
-- M.global_config_path() (both mainly for tests).
function M.resolve(overrides)
    overrides = overrides or {}
    local config_file, root_dir
    if overrides.config_path then
        config_file = overrides.config_path
    else
        config_file, root_dir = M.find_config(overrides.start_dir)
    end

    local local_cfg = config_file and M.load(config_file) or {}
    local global_cfg = M.load(overrides.global_config_path or M.global_config_path())

    local cfg = {}
    for key, default in pairs(M.DEFAULTS) do
        cfg[key] = overrides[key] or local_cfg[key] or global_cfg[key] or default
    end

    local cwd = tmio.realpath(overrides.start_dir or ".")
    local in_sub = root_dir and cwd and root_dir ~= cwd

    if not overrides.tasks_dir and in_sub and not cfg.tasks_dir:match("^/") and not cfg.tasks_dir:match("^~") then
        if local_cfg.tasks_dir then
            cfg.tasks_dir = root_dir .. "/" .. cfg.tasks_dir
        else
            -- No tasks_dir configured; resolve default/legacy relative to root_dir
            if tmio.dir_exists(root_dir .. "/" .. cfg.tasks_dir) then
                cfg.tasks_dir = root_dir .. "/" .. cfg.tasks_dir
            elseif tmio.dir_exists(root_dir .. "/" .. M.LEGACY_TASKS_DIR) then
                cfg.tasks_dir = root_dir .. "/" .. M.LEGACY_TASKS_DIR
            else
                cfg.tasks_dir = root_dir .. "/" .. cfg.tasks_dir
            end
        end
    else
        if not (overrides.tasks_dir or local_cfg.tasks_dir or global_cfg.tasks_dir)
            and not tmio.dir_exists(cfg.tasks_dir)
            and tmio.dir_exists(M.LEGACY_TASKS_DIR) then
            cfg.tasks_dir = M.LEGACY_TASKS_DIR
        end
    end

    cfg.active_path    = cfg.tasks_dir .. "/" .. cfg.active_file
    cfg.future_path    = cfg.tasks_dir .. "/" .. cfg.future_file
    cfg.completed_path = cfg.tasks_dir .. "/" .. cfg.completed_file

    return cfg
end

return M
