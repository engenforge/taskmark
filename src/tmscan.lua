#!/usr/bin/env lua
-- tmscan.lua — SPEC-TASKMARK-04 §7 single-pass line scanner. Classifies
-- each body line into exactly one kind, from its own leading characters
-- alone. No document tree, no whole-file retention, no dependencies.
local M = {}

-- A fence delimiter run: three or more of the same fence character at the
-- very start of `content` (§4.4.1 -- content never carries leading
-- whitespace outside a fence, so the marker is always column 5). Returns
-- the character and run length, or nil if `content` does not open with one.
local function fence_run(content)
    local backticks = content:match("^(`+)")
    if backticks and #backticks >= 3 then return "`", #backticks end
    local tildes = content:match("^(~+)")
    if tildes and #tildes >= 3 then return "~", #tildes end
    return nil
end

-- Whether `content` opens a fence: same as fence_run, but a plain boolean
-- shape for callers that only need to know "is this a fence marker line".
local function is_fence_marker(content)
    return fence_run(content) ~= nil
end

-- Whether `content` opens a fence. Returns char, length -- callers track
-- these across lines to test a later line against M.fence_closes.
function M.fence_opens(content)
    return fence_run(content)
end

-- Whether `content` closes a fence that was opened with `open_char` /
-- `open_len`: a run of at least `open_len` of that same character, with
-- nothing but trailing whitespace after it -- a closing marker can't carry
-- an info string. A mismatched character or a shorter run never closes it.
function M.fence_closes(content, open_char, open_len)
    local char, len = fence_run(content)
    if not char or char ~= open_char or len < open_len then return false end
    return content:sub(len + 1):match("^%s*$") ~= nil
end

-- Classify one line. Returns kind ("heading" | "task" | "payload" |
-- "blank" | "prose") and a fields table describing it.
function M.classify(line)
    if line:match("^%s*$") then
        return "blank", {}
    end

    local hashes, text = line:match("^(#+) (.*)$")
    if hashes then
        return "heading", { level = #hashes, text = text }
    end

    local marker, rest = line:match("^%- %[([ x])%] (.*)$")
    if marker then
        local priority, description = rest:match("^%(([A-Z])%) (.*)$")
        if not priority then
            description = rest
        end
        return "task", { done = marker == "x", priority = priority, description = description }
    end

    if line:sub(1, 4) == "    " then
        return "payload", { prefix = "    ", content = line:sub(5) }
    end

    return "prose", { text = line }
end

-- An iterator over classified lines. Yields, per call:
--   index, kind, fields, heading, task, fence_open
-- `heading` is the current heading text (nil before the first heading).
-- `task` is the fields table of the current task (nil outside one).
-- `fence_open` is whether a fenced code block is currently open inside
-- the current payload.
function M.iter(lines)
    local i = 0
    local heading, task, fence_open = nil, nil, false
    local fence_char, fence_len = nil, nil
    return function()
        i = i + 1
        if i > #lines then return nil end
        local kind, fields = M.classify(lines[i])
        if kind == "heading" then
            heading, task, fence_open, fence_char, fence_len = fields.text, nil, false, nil, nil
        elseif kind == "task" then
            task, fence_open, fence_char, fence_len = fields, false, nil, nil
        elseif kind == "prose" then
            task, fence_open, fence_char, fence_len = nil, false, nil, nil
        elseif kind == "payload" then
            if fence_open then
                if M.fence_closes(fields.content, fence_char, fence_len) then
                    fence_open, fence_char, fence_len = false, nil, nil
                end
            else
                local char, len = fence_run(fields.content)
                if char then
                    fence_open, fence_char, fence_len = true, char, len
                end
            end
        end
        return i, kind, fields, heading, task, fence_open
    end
end

-- Every task, with its payload's line range. A task's payload extends
-- from the line after it through the last line that is either blank or
-- payload-indented (§4.4.1); a task with no such lines has no payload,
-- and payload_start/payload_end are nil.
function M.tasks(lines)
    local results = {}
    local heading = nil
    local i = 1
    while i <= #lines do
        local kind, fields = M.classify(lines[i])
        if kind == "heading" then
            heading = fields.text
            i = i + 1
        elseif kind == "task" then
            local task_line = i
            local payload_start = i + 1
            local had_payload_line = false
            local j = payload_start
            while j <= #lines do
                local k = M.classify(lines[j])
                if k == "payload" then
                    had_payload_line = true
                elseif k ~= "blank" then
                    break
                end
                j = j + 1
            end
            results[#results + 1] = {
                line = task_line,
                done = fields.done,
                priority = fields.priority,
                description = fields.description,
                heading = heading,
                payload_start = had_payload_line and payload_start or nil,
                payload_end = had_payload_line and (j - 1) or nil,
            }
            i = j
        else
            i = i + 1
        end
    end
    return results
end

-- ── Plain string utilities (moved off the retired AST engine; pure Lua) ────

-- Detect newline format of content (\r\n vs \n) based on the first line break.
function M.detect_newline(content)
    if not content then return "\n" end
    local first_nl = content:match("\r?\n")
    if first_nl == "\r\n" then
        return "\r\n"
    end
    return "\n"
end

-- Split a text string into an array of line strings.
function M.lines_of(s)
    if not s or s == "" then return {} end
    local lines = {}
    local text = s:match("\n$") and s or (s .. "\n")
    for line in text:gmatch("(.-)\r?\n") do
        table.insert(lines, line)
    end
    return lines
end

local function is_leap_year(y)
    return (y % 4 == 0 and y % 100 ~= 0) or (y % 400 == 0)
end

local function days_in_month(y, m)
    if m < 1 or m > 12 then return 0 end
    local dim = { 31, is_leap_year(y) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    return dim[m]
end

-- Convert Gregorian civil date to days since Unix epoch (1970-01-01) in pure UTC.
local function days_from_civil(y, m, d)
    y = y - (m <= 2 and 1 or 0)
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m > 2 and m - 3 or m + 9) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- Parse an ISO-8601 timestamp (full timestamp or bare YYYY-MM-DD date) to
-- UTC epoch seconds. Validates calendar ranges (e.g. rejects 2026-13-45).
-- Deterministic and timezone-independent (never uses local os.time).
function M.parse_iso8601(s)
    if not s then return nil end
    local y, mo, d, H, Mi, S = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)")
    if y then
        y, mo, d, H, Mi, S = tonumber(y), tonumber(mo), tonumber(d), tonumber(H), tonumber(Mi), tonumber(S)
        if mo < 1 or mo > 12 or d < 1 or d > days_in_month(y, mo) or H < 0 or H > 23 or Mi < 0 or Mi > 59 or S < 0 or S > 60 then
            return nil
        end
        local days = days_from_civil(y, mo, d)
        return days * 86400 + H * 3600 + Mi * 60 + S
    end
    y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    if y then
        y, mo, d = tonumber(y), tonumber(mo), tonumber(d)
        if mo < 1 or mo > 12 or d < 1 or d > days_in_month(y, mo) then
            return nil
        end
        local days = days_from_civil(y, mo, d)
        return days * 86400
    end
    return nil
end

return M
