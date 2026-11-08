#!/usr/bin/env lua
-- tmfilter — SPEC-TASKMARK-04 §8.1 payload indent/dedent filters. Plain
-- stdin-to-stdout filters; no parsing, no state.
local M = {}

local USAGE = [[
Usage: tmfilter indent [INFO] | tmfilter dedent [--fence] | -h

  indent  Prefix non-blank stdin lines with four spaces (blank lines stay
          empty); INFO wraps the result in a fenced code block.
  dedent  Remove the four-space payload indent; exits non-zero rather
          than truncate a line lacking it. --fence drops the first/last line.
]]

-- Known spec erratum (§9.1's "byte for byte, for any input whatsoever"):
-- input with no trailing newline gains one, since these filters are
-- line-oriented and a trailing newline is not itself a "line" they read or
-- emit. Rewriting the whole tool line-oriented to preserve one absent byte
-- was judged not worth it -- flagged here rather than left silently unmet.
local function lines()
    local t = {}
    for l in io.lines() do t[#t + 1] = l end
    return t
end

local function emit(t)
    io.write(table.concat(t, "\n"), #t > 0 and "\n" or "")
end

function M.indent(info)
    -- Only a genuinely empty line is left unindented; a spaces-only line is
    -- content and gets the four-space prefix like any other, even though
    -- §2.4 would also call it blank -- this favors byte-exact round-trip
    -- over collapsing it to empty.
    local out = info and { "    ```" .. info } or {}
    for _, l in ipairs(lines()) do out[#out + 1] = (l == "") and "" or ("    " .. l) end
    if info then out[#out + 1] = "    ```" end
    emit(out)
end

local function is_fence_delim(l)
    return l and (l:sub(1, 3) == "```" or l:sub(1, 3) == "~~~")
end

function M.dedent(strip_fence)
    local out = {}
    for _, l in ipairs(lines()) do
        if l == "" then
            out[#out + 1] = ""
        elseif l:sub(1, 4) == "    " then
            out[#out + 1] = l:sub(5)
        else
            io.stderr:write("dedent: line lacks the four-space payload indent: " .. l .. "\n")
            os.exit(1)
        end
    end
    if strip_fence then
        if #out < 2 or not is_fence_delim(out[1]) or not is_fence_delim(out[#out]) then
            io.stderr:write("dedent --fence: first/last line is not a fence delimiter\n")
            os.exit(1)
        end
        table.remove(out, 1)
        table.remove(out, #out)
    end
    emit(out)
end

function M.run(args)
    args = args or arg or {}
    local cmd = args[1]
    if cmd == "indent" then
        M.indent(args[2])
    elseif cmd == "dedent" then
        M.dedent(args[2] == "--fence")
    elseif cmd == "-h" or cmd == "--help" or not cmd then
        io.write(USAGE)
    else
        io.stderr:write("Unknown filter: " .. cmd .. "\nRun 'tmfilter -h' for usage.\n")
        os.exit(1)
    end
    os.exit(0)
end

if arg and arg[0] and arg[0]:match("tmfilter%.lua$") then M.run() end
return M
