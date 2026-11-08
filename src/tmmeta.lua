#!/usr/bin/env lua
-- tmmeta.lua — SPEC-TASKMARK-04 §9.1 flat `key: value` reader for the
-- configuration files (.taskmarkrc and the global config). Task documents
-- carry no metadata block of their own. No dependencies.
local M = {}

local function strip_quotes(value)
    local first, last = value:sub(1, 1), value:sub(-1)
    if #value >= 2 and ((first == "'" and last == "'") or (first == '"' and last == '"')) then
        return value:sub(2, -2)
    end
    return value
end

-- Parse lines (no newlines) into a key/value table. Returns tbl; or nil,
-- reason, line index of the first invalid line or duplicate key.
-- opts.relaxed skips blank lines and '#'-led lines; otherwise both error.
function M.parse_lines(lines, opts)
    local relaxed = opts and opts.relaxed
    local tbl = {}
    for i, line in ipairs(lines) do
        if not (relaxed and (line:match("^%s*$") or line:match("^%s*#"))) then
            local key, value = line:match("^([%a][%w_-]*): (.*)$")
            if not key then return nil, string.format("line %d is not a valid key: value line", i), i end
            if tbl[key] ~= nil then return nil, string.format("duplicate key %q at line %d", key, i), i end
            tbl[key] = strip_quotes((value:gsub("%s+$", "")))
        end
    end
    return tbl
end

return M
