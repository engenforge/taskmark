#!/usr/bin/env lua
-- tmio.lua — tiny shared filesystem helpers (existence checks, mkdir -p,
-- and atomic writes) used by tminit and tmsweep. No parsing, no state.
local M = {}

function M.file_exists(path)
    local f = io.open(path, "r")
    if not f then return false end
    f:close()
    return true
end

-- Quote a string for safe inclusion in a shell command.
function M.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function M.mkdir_p(dir)
    os.execute("mkdir -p " .. M.shell_quote(dir))
end

function M.die(msg)
    io.stderr:write(msg .. "\n")
    os.exit(1)
end

-- Write `content` via a temp file and rename, so an interrupted run cannot
-- leave a half-written document behind. Returns true, or nil, reason.
function M.write_file_atomic(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return nil, "cannot write: " .. tmp end
    f:write(content)
    f:close()
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return nil, "cannot replace " .. path .. ": " .. tostring(err)
    end
    return true
end

return M
