#!/usr/bin/env lua
-- tmmeta.lua — SPEC-TASKMARK-03 §2.2.1 flat `key: value` reader/writer,
-- shared by frontmatter (§2.2) and configuration (§10.1). No dependencies.
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

-- Split a file's line array on its leading frontmatter block. Returns
-- tbl, body_start_index, raw_span; or nil, reason ("missing",
-- "unterminated", "bad_line"), and -- for "bad_line" -- the 1-based line
-- index of the offending line within the frontmatter block (span, not
-- the whole file) on failure.
function M.split_frontmatter(lines)
    if lines[1] ~= "---" then return nil, "missing" end
    local close
    for i = 2, #lines do
        if lines[i] == "---" then close = i; break end
    end
    if not close then return nil, "unterminated" end
    local span = {}
    for i = 2, close - 1 do
        span[#span + 1] = lines[i]
    end
    local tbl, _, bad_line = M.parse_lines(span)
    if not tbl then return nil, "bad_line", bad_line end
    return tbl, close + 1, span
end

-- Render a key/value table to "key: value" lines: keys in `order` (that
-- exist in tbl) first, then remaining keys sorted lexicographically.
function M.render(tbl, order)
    local lines, used = {}, {}
    for _, key in ipairs(order or {}) do
        if tbl[key] ~= nil and not used[key] then
            lines[#lines + 1] = key .. ": " .. tbl[key]
            used[key] = true
        end
    end
    local rest = {}
    for key in pairs(tbl) do
        if not used[key] then rest[#rest + 1] = key end
    end
    table.sort(rest)
    for _, key in ipairs(rest) do
        lines[#lines + 1] = key .. ": " .. tbl[key]
    end
    return lines
end

-- Replace one field's value in a file's frontmatter block ("key: " lines
-- only -- a value containing that exact prefix elsewhere on the line is not
-- touched), leaving every other line byte-identical. Returns the new line
-- array, or nil, reason.
function M.set_field(lines, key, value)
    local tbl, body_start = M.split_frontmatter(lines)
    if not tbl then return nil, body_start end
    local prefix = key .. ": "
    local out = {}
    for i = 1, body_start - 1 do
        out[i] = lines[i]:sub(1, #prefix) == prefix and (prefix .. value) or lines[i]
    end
    for i = body_start, #lines do
        out[i] = lines[i]
    end
    return out
end

-- Replace the `date:` value the same way set_field replaces any field.
function M.set_date(lines, date)
    return M.set_field(lines, "date", date)
end

return M
