#!/usr/bin/env lua
-- tests/testgit.lua — the one place test suites get an isolated git.
--
-- A test that runs git must never see the developer's git configuration:
-- a global signing key prompts for its PIN (or signs scratch commits),
-- and global hooks, identity, and defaults change what the test exercises.
-- Every suite that runs git starts with
--
--     package.path = ((arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
--     local HAVE_GIT = require("testgit").isolate()
--
-- which re-runs the suite under ENV below when it is not already isolated,
-- and returns whether git is installed. `make test` checks that every
-- suite mentioning a git command does this (check-test-isolation), and
-- runs each suite under the same ENV (`lua tests/testgit.lua env`).
--
-- Only tests use this. tm itself runs git with the user's configuration,
-- so the user's hooks and signing apply to the commits tm makes.

local M = {}

-- The isolated environment, in a fixed order.
M.ENV = {
    { "GIT_CONFIG_GLOBAL",   "/dev/null" },
    { "GIT_CONFIG_NOSYSTEM", "1" },
    { "GIT_CONFIG_COUNT",    "0" },  -- drops GIT_CONFIG_KEY_n/VALUE_n injected config
    { "GIT_AUTHOR_NAME",     "tm-test" },
    { "GIT_AUTHOR_EMAIL",    "tm-test@example.invalid" },
    { "GIT_COMMITTER_NAME",  "tm-test" },
    { "GIT_COMMITTER_EMAIL", "tm-test@example.invalid" },
}

local function quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- `K=V ...` for every entry of ENV, shell-quoted.
function M.env_assignments()
    local out = {}
    for _, kv in ipairs(M.ENV) do out[#out + 1] = kv[1] .. "=" .. quote(kv[2]) end
    return table.concat(out, " ")
end

-- Whether this process already runs under ENV. Checked variable by
-- variable, never trusted from a flag, so a partial environment re-runs.
function M.isolated()
    for _, kv in ipairs(M.ENV) do
        if os.getenv(kv[1]) ~= kv[2] then return false end
    end
    return true
end

local function exit_ok(ok, _, code)
    if type(ok) == "number" then return ok == 0 end
    return ok == true and code == 0
end

-- Whether git is installed.
function M.available()
    return exit_ok(os.execute("git --version >/dev/null 2>&1"))
end

-- Make the running suite isolated: when it is not, run it again under ENV
-- with the same interpreter and arguments, and exit with its status. Git
-- is optional for building and testing Taskmark, so a suite that cannot
-- work without it passes opts.skip_without_git (a name to report): it then
-- prints [SKIP] and exits 0 when git is missing. Returns whether git is
-- installed.
function M.isolate(opts)
    opts = opts or {}
    local have_git = M.available()
    if not have_git and opts.skip_without_git then
        print("[SKIP] " .. opts.skip_without_git .. ": git is not installed")
        os.exit(0)
    end
    if M.isolated() then return have_git end
    if os.getenv("TM_TESTGIT_REEXEC") == "1" then
        error("testgit: still not isolated after re-running under the isolated environment")
    end
    local cmd = { "env", "TM_TESTGIT_REEXEC=1", M.env_assignments(), quote(arg[-1] or "lua"), quote(arg[0]) }
    for i = 1, #arg do cmd[#cmd + 1] = quote(arg[i]) end
    os.exit(exit_ok(os.execute(table.concat(cmd, " "))) and 0 or 1)
end

-- `lua tests/testgit.lua env` prints the assignments, for the Makefile.
if arg and arg[0] and arg[0]:match("testgit%.lua$") and arg[1] == "env" then
    print(M.env_assignments())
end

return M
