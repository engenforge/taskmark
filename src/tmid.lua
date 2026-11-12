#!/usr/bin/env lua
-- tmid.lua — SPEC-TASKMARK-05 §4.3.3 task identifiers (`id:k7q2x` on the
-- task line) and the `Depends` field that cites them (§4.4.2).
--
-- An identifier is drawn at random and checked against every task file, so
-- allocation needs no counter and no index: nothing to go stale or to
-- conflict when two branches merge.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path

local tmscan = require("tmscan")
local tmio   = require("tmio")

local M = {}

-- Crockford base32, lowercase: no i, l, o, or u, so no symbol can be
-- misread as another. 256 is a multiple of 32, so a byte maps on unbiased.
M.ALPHABET   = "0123456789abcdefghjkmnpqrstvwxyz"
M.LENGTH     = 5
M.MIN_LENGTH = 4
M.PREFIX     = "id:"

local function valid(id)
    return #id >= M.MIN_LENGTH and id:match("^[0-9a-z]+$") ~= nil
end

-- The identifier of a task line or summary: its first whole word of the
-- form `id:` plus four or more lowercase letters and digits. nil if none.
function M.of(text)
    for word in (text or ""):gmatch("%S+") do
        if word:sub(1, #M.PREFIX) == M.PREFIX then
            local id = word:sub(#M.PREFIX + 1)
            if valid(id) then return id end
        end
    end
    return nil
end

-- Every identifier cited in free text (a Depends value), in order.
function M.refs(text)
    local out = {}
    for id in (text or ""):gmatch("%f[%w]id:([0-9a-z]+)") do
        if valid(id) then out[#out + 1] = id end
    end
    return out
end

local function urandom(n)
    local f = io.open("/dev/urandom", "rb")
    if not f then return nil end
    local bytes = f:read(n)
    f:close()
    return bytes
end

-- Draw one identifier. `read_bytes(n)` supplies entropy (default:
-- /dev/urandom). A clock-seeded fallback is deliberately absent: two
-- agents started in the same second would draw the same identifier.
function M.generate(read_bytes)
    local bytes = (read_bytes or urandom)(M.LENGTH)
    if not bytes or #bytes < M.LENGTH then
        return nil, "cannot read /dev/urandom to draw a task identifier"
    end
    local out = {}
    for i = 1, M.LENGTH do
        local idx = bytes:byte(i) % #M.ALPHABET + 1
        out[i] = M.ALPHABET:sub(idx, idx)
    end
    return table.concat(out)
end

-- Whether `id` occurs anywhere in `texts` -- on a task line, in a Depends
-- field, or in prose: a new task must never satisfy an old reference, so
-- any occurrence counts as taken. A plain search first; the word-boundary
-- check runs only on a hit, so `id:z0114` does not take `id:z01140`.
function M.taken(id, texts)
    local needle = M.PREFIX .. id
    for _, text in ipairs(texts) do
        if text:find(needle, 1, true) and text:find(needle .. "%f[^0-9a-z]") then return true end
    end
    return false
end

-- An identifier that occurs nowhere in `texts`. Returns id; or nil, reason.
function M.fresh(texts, generate)
    for _ = 1, 100 do
        local id, err = (generate or M.generate)()
        if not id then return nil, err end
        if not M.taken(id, texts) then return id end
    end
    return nil, "could not draw an unused task identifier"
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- Every existing task file of a resolved configuration: active, future,
-- completed, then the archive files in name order.
function M.task_files(cfg)
    local out = {}
    for _, path in ipairs({ cfg.active_path, cfg.future_path, cfg.completed_path }) do
        local f = io.open(path, "r")
        if f then f:close(); out[#out + 1] = path end
    end
    local p = io.popen("find " .. tmio.shell_quote(cfg.tasks_dir .. "/" .. cfg.archive_dir) ..
        " -type f -name '*.tm.md' 2>/dev/null | LC_ALL=C sort")
    if p then
        for path in p:lines() do out[#out + 1] = path end
        p:close()
    end
    return out
end

-- The contents of `paths`, skipping any that cannot be read.
function M.read_texts(paths)
    local out = {}
    for _, path in ipairs(paths) do
        out[#out + 1] = read(path)
    end
    return out
end

-- Task lines of `content` that carry an identifier: { id, line, done }.
local function identified_tasks(content)
    local out = {}
    for i, line in ipairs(tmscan.lines_of(content)) do
        local kind, fields = tmscan.classify(line)
        if kind == "task" then
            local id = M.of(fields.description)
            if id then out[#out + 1] = { id = id, line = i, done = fields.done } end
        end
    end
    return out
end

-- Identifiers carried by more than one task line across `paths`, in order
-- of first appearance: { id, places = { { path, line }, ... } }.
function M.duplicates(paths)
    local by_id, order = {}, {}
    for _, path in ipairs(paths) do
        local content = read(path)
        if content and content:find(M.PREFIX, 1, true) then
            for _, t in ipairs(identified_tasks(content)) do
                if not by_id[t.id] then
                    by_id[t.id] = {}
                    order[#order + 1] = t.id
                end
                table.insert(by_id[t.id], { path = path, line = t.line })
            end
        end
    end
    local out = {}
    for _, id in ipairs(order) do
        if #by_id[id] > 1 then out[#out + 1] = { id = id, places = by_id[id] } end
    end
    return out
end

-- One line describing a duplicates() entry, for a warning.
function M.describe_duplicate(d)
    local places = {}
    for _, p in ipairs(d.places) do places[#places + 1] = p.path .. ":" .. p.line end
    return string.format("%s%s is carried by %d tasks: %s", M.PREFIX, d.id, #d.places, table.concat(places, ", "))
end

-- Whether the task named `id` is "pending" or "done", searching `paths` in
-- order; nil when no task line carries it. A pending copy wins over a
-- completed one, so a duplicated identifier never unblocks a dependant.
function M.status(id, paths)
    local found
    for _, path in ipairs(paths) do
        local content = read(path)
        if content and content:find(M.PREFIX .. id, 1, true) then
            for _, t in ipairs(identified_tasks(content)) do
                if t.id == id then
                    if not t.done then return "pending" end
                    found = "done"
                end
            end
        end
    end
    return found
end

-- The identifiers a task's `Depends` field cites (§4.4.2), read from the
-- whole payload outside fenced code, continuation lines included.
function M.depends(lines, task)
    local out = {}
    if not task.payload_start then return out end
    local fence_char, fence_len
    local in_depends = false
    for i = task.payload_start, task.payload_end do
        local kind, fields = tmscan.classify(lines[i])
        local content = kind == "payload" and fields.content or ""
        if fence_char then
            if tmscan.fence_closes(content, fence_char, fence_len) then fence_char, fence_len = nil, nil end
            in_depends = false
        else
            local key, value = content:match("^> %*%*([A-Za-z][A-Za-z0-9_%-]*):%*%* ?(.*)$")
            if key then
                in_depends = key == "Depends"
            elseif in_depends and content:match("^> ") then
                value = content:sub(3)
            else
                in_depends = false
                fence_char, fence_len = tmscan.fence_opens(content)
            end
            if in_depends and value then
                for _, id in ipairs(M.refs(value)) do out[#out + 1] = id end
            end
        end
    end
    return out
end

return M
