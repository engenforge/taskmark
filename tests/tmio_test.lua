#!/usr/bin/env lua
-- tests/tmio_test.lua — unit tests for src/tmio.lua
-- Tests file existence, shell quoting, mkdir_p, and collision-safe atomic writes.

local script_dir = (arg[0] or "./tests/tmio_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmio = require("tmio")

local passed, failed = 0, 0

local function check(group, name, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s: %s", group, name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s: %s%s", group, name, detail and (" -- " .. detail) or ""))
    end
end

local function clean_dir(dir)
    os.execute("rm -rf " .. tmio.shell_quote(dir))
end

local test_sandbox = "build/test_tmio_sandbox"
clean_dir(test_sandbox)
tmio.mkdir_p(test_sandbox)

-- ── file_exists ────────────────────────────────────────────────────────────

do
    local existing = test_sandbox .. "/exists.txt"
    local f = io.open(existing, "w")
    f:write("hello")
    f:close()

    check("file_exists", "returns true for existing file", tmio.file_exists(existing) == true)
    check("file_exists", "returns false for nonexistent file", tmio.file_exists(test_sandbox .. "/no_such_file.txt") == false)
end

-- ── shell_quote ────────────────────────────────────────────────────────────

do
    check("shell_quote", "quotes simple string", tmio.shell_quote("hello") == "'hello'")
    check("shell_quote", "quotes string with spaces", tmio.shell_quote("hello world") == "'hello world'")
    check("shell_quote", "escapes single quotes inside string", tmio.shell_quote("it's cool") == "'it'\\''s cool'")
end

-- ── mkdir_p ────────────────────────────────────────────────────────────────

do
    local nested = test_sandbox .. "/a/b/c/d"
    local ok = tmio.mkdir_p(nested)
    check("mkdir_p", "creates deeply nested directory", tmio.file_exists(nested) == true)
    check("mkdir_p", "handles nil and empty gracefully", tmio.mkdir_p(nil) == true and tmio.mkdir_p("") == true and tmio.mkdir_p(".") == true)
end

-- ── write_file_atomic ──────────────────────────────────────────────────────

do
    local target = test_sandbox .. "/atomic.txt"
    local ok, err = tmio.write_file_atomic(target, "atomic content\n")
    check("write_file_atomic", "writes content successfully", ok == true)

    local f = io.open(target, "r")
    local body = f and f:read("*a")
    if f then f:close() end
    check("write_file_atomic", "content matches exactly", body == "atomic content\n")

    -- Verify no stray .tmp or .tmp.* files left behind
    local handle = io.popen(string.format("ls -A %s", tmio.shell_quote(test_sandbox)))
    local listing = handle:read("*a")
    handle:close()
    local has_stray_tmp = listing:find("%.tmp") ~= nil
    check("write_file_atomic", "leaves no temporary files behind", not has_stray_tmp)
end

-- ── collision safety / unique temp filename ────────────────────────────────

do
    -- Verify temp name generator produces unique, randomized filenames per call
    if type(tmio.temp_path_for) == "function" then
        local target = test_sandbox .. "/target.txt"
        local t1 = tmio.temp_path_for(target)
        local t2 = tmio.temp_path_for(target)
        check("temp_path_for", "generates non-static temp path", t1 ~= target .. ".tmp")
        check("temp_path_for", "generates unique temp path on successive calls", t1 ~= t2)
        check("temp_path_for", "temp path stays in same directory for atomic rename",
            t1:match("^(.*)/") == target:match("^(.*)/"))
    else
        check("temp_path_for", "tmio.temp_path_for exists", false, "function missing")
    end
end

-- ── failure cleanup ────────────────────────────────────────────────────────

do
    -- Attempting to write into a nonexistent directory should fail gracefully
    local bad_target = test_sandbox .. "/nonexistent_dir/file.txt"
    local ok, err = tmio.write_file_atomic(bad_target, "fail")
    check("write_file_atomic", "returns nil and error message on write failure", ok == nil and type(err) == "string")
end

-- A failed write or flush (e.g. a full disk) must never be renamed over the
-- original: the original stays intact and the partial temp file is removed.
local function with_failing_handle(fail_on, fn)
    local real_open = io.open
    io.open = function(path, mode)
        if mode == "w" and path:find("%.tmp%.") then
            local fh = real_open(path, mode)
            return {
                write = function(self, s)
                    if fail_on == "write" then return nil, "No space left on device" end
                    return fh:write(s)
                end,
                close = function(self)
                    fh:close()
                    if fail_on == "close" then return nil, "No space left on device" end
                    return true
                end,
            }
        end
        return real_open(path, mode)
    end
    local ok, a, b = pcall(fn)
    io.open = real_open
    if not ok then error(a) end
    return a, b
end

for _, fail_on in ipairs({ "write", "close" }) do
    local target = test_sandbox .. "/precious_" .. fail_on .. ".txt"
    local f = io.open(target, "w")
    f:write("original\n")
    f:close()

    local ok, err = with_failing_handle(fail_on, function()
        return tmio.write_file_atomic(target, "replacement\n")
    end)
    check("write_file_atomic", "failed " .. fail_on .. " returns nil, reason",
        ok == nil and type(err) == "string" and err:find("No space", 1, true) ~= nil, tostring(err))

    local rf = io.open(target, "r")
    local body = rf:read("*a")
    rf:close()
    check("write_file_atomic", "failed " .. fail_on .. " leaves original intact", body == "original\n", body)

    local handle = io.popen(string.format("ls -A %s", tmio.shell_quote(test_sandbox)))
    local listing = handle:read("*a")
    handle:close()
    check("write_file_atomic", "failed " .. fail_on .. " removes its temp file", listing:find("%.tmp") == nil, listing)
end

-- ── concurrent writers ─────────────────────────────────────────────────────

do
    -- Several real processes rewrite one file at once. Every writer must
    -- succeed, the result must be exactly one writer's complete content,
    -- and no temp file may survive.
    local target = test_sandbox .. "/contended.txt"
    local src = script_dir .. "/../src"
    local writers, rounds = 6, 25
    local cmds = {}
    for w = 1, writers do
        local body = string.rep(string.format("writer %d\n", w), 200)
        local lua_src = string.format(
            "package.path=%q..'/?.lua;'..package.path; local io_=require('tmio'); " ..
            "for _=1,%d do local ok,err=io_.write_file_atomic(%q,%q); if not ok then io.stderr:write(err..'\\n'); os.exit(1) end end",
            src, rounds, target, body)
        cmds[#cmds + 1] = "lua -e " .. tmio.shell_quote(lua_src) .. " || echo WRITER_FAILED"
    end
    local p = io.popen("( " .. table.concat(cmds, " & ") .. " & wait ) 2>&1")
    local out = p:read("*a")
    p:close()
    check("concurrent", "every concurrent writer succeeds", not out:find("WRITER_FAILED", 1, true), out)

    local f = io.open(target, "r")
    local body = f and f:read("*a") or ""
    if f then f:close() end
    local whole = body:match("^writer (%d+)\n") and body == string.rep("writer " .. body:match("^writer (%d+)") .. "\n", 200)
    check("concurrent", "result is one writer's complete content", whole)

    local handle = io.popen(string.format("ls -A %s", tmio.shell_quote(test_sandbox)))
    local listing = handle:read("*a")
    handle:close()
    check("concurrent", "no temp files survive", listing:find("%.tmp") == nil, listing)
end

-- ── directory lock ─────────────────────────────────────────────────────────

do
    local dir = test_sandbox .. "/locked"
    tmio.mkdir_p(dir)

    check("lock", "acquire on a free directory", tmio.acquire_lock(dir, { retries = 0 }) == true)
    local ok, err = tmio.acquire_lock(dir, { retries = 0 })
    check("lock", "second acquire fails while held", ok == nil and type(err) == "string" and err:find(".tm.lock", 1, true) ~= nil, tostring(err))
    tmio.release_lock(dir)
    check("lock", "lock path removed on release", not tmio.file_exists(dir .. "/.tm.lock"))
    check("lock", "acquire succeeds again after release", tmio.acquire_lock(dir, { retries = 0 }) == true)
    tmio.release_lock(dir)

    -- with_lock releases on a raised error and re-raises it.
    local pok, perr = pcall(tmio.with_lock, dir, function() error("boom") end)
    check("lock", "with_lock re-raises errors", not pok and tostring(perr):find("boom", 1, true) ~= nil)
    check("lock", "with_lock releases after an error", not tmio.file_exists(dir .. "/.tm.lock"))
    check("lock", "with_lock returns fn's results", tmio.with_lock(dir, function() return 42 end) == 42)

    -- die() (os.exit) inside a held lock must not leave it stale.
    local src = script_dir .. "/../src"
    local lua_src = string.format(
        "package.path=%q..'/?.lua;'..package.path; local io_=require('tmio'); " ..
        "io_.with_lock(%q, function() io_.die('fatal') end)", src, dir)
    os.execute("lua -e " .. tmio.shell_quote(lua_src) .. " 2>/dev/null")
    check("lock", "die releases held locks", not tmio.file_exists(dir .. "/.tm.lock"))
end

-- ── mkdir_p failure ────────────────────────────────────────────────────────

do
    local blocker = test_sandbox .. "/blocker.txt"
    local f = io.open(blocker, "w")
    f:write("x")
    f:close()
    check("mkdir_p", "returns false when the path cannot be created", tmio.mkdir_p(blocker .. "/sub") == false)
end

clean_dir(test_sandbox)

print(string.format("\nResults: %d passed, %d failed, %d total", passed, failed, passed + failed))
if failed > 0 then os.exit(1) end
