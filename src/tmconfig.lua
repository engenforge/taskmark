#!/usr/bin/env lua
-- tmconfig — SPEC-TASKMARK-03 §10 configuration resolution.
--
-- Resolves the on-disk paths tm's subcommands operate on (the doc/tasks/
-- directory itself, active.tm.md/future.tm.md/completed.tm.md, the archive/
-- subdirectory name, and the hub locations) from, per key, in order of
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
-- Both files are parsed with the same relaxed flat `key: value` reader as
-- frontmatter (§2.2.1 / §10.1); no serialization dependency of any kind.

local function self_dir()
    local s = (debug.getinfo and debug.getinfo(1, "S").source:match("^@(.*)$")) or (arg and arg[0]) or "."
    return s:match("^(.*)/[^/]+$") or "."
end

do
    local dir = self_dir()
    package.path = dir .. "/?.lua;" .. dir .. "/../share/tm/?.lua;" .. package.path
end

local tmmeta = require("tmmeta")

local M = {}

-- Conventional paths this spec has always used, unchanged when no
-- configuration is present.
M.DEFAULTS = {
    tasks_dir      = "doc/tasks",
    active_file    = "active.tm.md",
    future_file    = "future.tm.md",
    completed_file = "completed.tm.md",
    archive_dir    = "archive",

    hub_dir        = "~/tasks",
    inbox_file     = "inbox.tm.md",
    dashboard_file = "dashboard.tm.md",
    registry_file  = "registry.txt",
}

M.CONFIG_FILENAME = ".taskmarkrc"

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
    local local_cfg = M.load(overrides.config_path)
    local global_cfg = M.load(overrides.global_config_path or M.global_config_path())

    local cfg = {}
    for key, default in pairs(M.DEFAULTS) do
        cfg[key] = overrides[key] or local_cfg[key] or global_cfg[key] or default
    end

    cfg.active_path    = cfg.tasks_dir .. "/" .. cfg.active_file
    cfg.future_path    = cfg.tasks_dir .. "/" .. cfg.future_file
    cfg.completed_path = cfg.tasks_dir .. "/" .. cfg.completed_file

    return cfg
end

return M
