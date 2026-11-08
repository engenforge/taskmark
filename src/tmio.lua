#!/usr/bin/env lua
-- tmio.lua — tiny shared filesystem helpers (existence checks, mkdir -p,
-- and collision-safe atomic writes) used by tminit and tmsweep. No parsing, no state.
local M = {}

local _counter = 0

function M.file_exists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

-- Quote a string for safe inclusion in a shell command.
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- os.execute's success value differs between Lua 5.1 (status 0) and 5.2+ (true).
local function exec_ok(cmd)
    local res = os.execute(cmd)
    return res == 0 or res == true
end

-- Create `dir` and any missing parents. Returns true, or false when the
-- directory could not be created; callers are expected to check.
function M.mkdir_p(dir)
    if not dir or dir == "" or dir == "." then return true end
    return exec_ok("mkdir -p " .. M.shell_quote(dir) .. " 2>/dev/null")
end

-- ── Advisory directory lock ───────────────────────────────────────────────
--
-- Unique temp names stop concurrent writers clobbering each other's temp
-- files, but not lost updates: two read-modify-write runs (an agent and a
-- human, two sweeps) can still interleave so the later rename discards the
-- earlier one's change. Every mutating command therefore holds a lock on
-- the task directory for its whole read-modify-write. `mkdir` is atomic on
-- every POSIX filesystem, so a lock directory needs nothing beyond plain Lua.

M.LOCK_NAME = ".tm.lock"

local held = {}

local function lock_path(dir)
    if not dir or dir == "" then dir = "." end
    return dir .. "/" .. M.LOCK_NAME
end

-- Acquire the lock on `dir`, retrying `opts.retries` times (default 50)
-- `opts.wait` seconds apart (default 0.1). Returns true, or nil, reason.
function M.acquire_lock(dir, opts)
    opts = opts or {}
    local retries = opts.retries or 50
    local wait = opts.wait or 0.1
    local path = lock_path(dir)
    for attempt = 0, retries do
        if exec_ok("mkdir " .. M.shell_quote(path) .. " 2>/dev/null") then
            held[path] = true
            return true
        end
        if attempt < retries then
            os.execute(string.format("sleep %s", tostring(wait)))
        end
    end
    return nil, "task directory is locked by another tm process: " .. path ..
        " (remove it if no tm process is running)"
end

function M.release_lock(dir)
    local path = lock_path(dir)
    if held[path] then
        os.remove(path)
        held[path] = nil
    end
end

function M.release_all_locks()
    for path in pairs(held) do
        os.remove(path)
        held[path] = nil
    end
end

-- Run fn(...) while holding the lock on `dir`; dies if the lock cannot be
-- acquired. The lock is released whether fn returns or raises (and by die(),
-- since os.exit bypasses the release here).
function M.with_lock(dir, fn, ...)
    local ok, err = M.acquire_lock(dir)
    if not ok then M.die(err) end
    local pok, result = pcall(fn, ...)
    M.release_lock(dir)
    if not pok then error(result, 0) end
    return result
end

function M.die(msg)
    M.release_all_locks()
    io.stderr:write(msg .. "\n")
    os.exit(1)
end

-- Generate a unique hex token from /dev/urandom when available,
-- falling back to table memory address, CPU clock, and pseudo-random numbers.
function M.unique_token()
    local urand = io.open("/dev/urandom", "rb")
    if urand then
        local bytes = urand:read(4)
        urand:close()
        if bytes and #bytes == 4 then
            local b1, b2, b3, b4 = bytes:byte(1, 4)
            return string.format("%02x%02x%02x%02x", b1, b2, b3, b4)
        end
    end
    local addr = tostring({}):match("0x(%x+)") or tostring({}):match("(%x+)$") or "0"
    local clk = math.floor((os.clock() or 0) * 1000000)
    local rnd = math.random(100000, 999999)
    return string.format("%s%x%x", addr, clk, rnd)
end

-- Construct a unique temporary file path residing in the same directory as `path`
-- to ensure an atomic inode rename without cross-filesystem errors.
function M.temp_path_for(path)
    _counter = _counter + 1
    local now = os.time()
    local token = M.unique_token()
    return string.format("%s.tmp.%d.%d.%s", path, now, _counter, token)
end

-- Write `content` via a unique temp file and rename, so an interrupted run cannot
-- leave a half-written document behind and concurrent writers do not collide.
-- Returns true, or nil, reason.
function M.write_file_atomic(path, content)
    local tmp = M.temp_path_for(path)
    local f = io.open(tmp, "w")
    if not f then return nil, "cannot write: " .. tmp end
    -- A short write or failed flush (e.g. a full disk) must never be
    -- renamed over the original document.
    local wrote, werr = f:write(content)
    local closed, cerr = f:close()
    if not wrote or not closed then
        os.remove(tmp)
        return nil, "cannot write " .. tmp .. ": " .. tostring(werr or cerr)
    end
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, "cannot replace " .. path .. ": " .. tostring(err)
    end
    return true
end

return M
