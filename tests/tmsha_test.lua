#!/usr/bin/env lua
-- tests/tmsha_test.lua — tests for tmsha.lua: `tm check-shas` and
-- `tm remap` over git:<sha> citations (SPEC-TASKMARK-05 §10.3).

-- Run hermetically, as tests/tmsync_test.lua does: scratch repositories
-- must not pick up the user's git configuration (signing, hooks, identity).
local function git_available()
    local ok, _, code = os.execute("git --version >/dev/null 2>&1")
    if type(ok) == "number" then return ok == 0 end
    return ok == true and code == 0
end
if not git_available() then
    print("[SKIP] tm check-shas / remap: git is not installed")
    os.exit(0)
end
if os.getenv("TM_TEST_GIT_ISOLATED") ~= "1" then
    local q = function(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
    local ok, _, code = os.execute(
        "env TM_TEST_GIT_ISOLATED=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 " ..
        "GIT_AUTHOR_NAME=tm-test GIT_AUTHOR_EMAIL=tm-test@example.invalid " ..
        "GIT_COMMITTER_NAME=tm-test GIT_COMMITTER_EMAIL=tm-test@example.invalid " ..
        q(arg[-1] or "lua") .. " " .. q(arg[0]))
    if type(ok) == "number" then os.exit(ok == 0 and 0 or 1) end
    os.exit((ok and code == 0) and 0 or 1)
end

local script_dir = (arg[0] or "./tests/tmsha_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmsha = require("tmsha")
local tmio  = require("tmio")

local passed, failed = 0, 0
local function check(group, name, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s: %s", group, name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s: %s%s", group, name, detail and (" -- " .. tostring(detail)) or ""))
    end
end
local function write(path, body)
    local f = assert(io.open(path, "w")); f:write(body); f:close()
end
local function read(path)
    local f = io.open(path, "r"); if not f then return nil end
    local b = f:read("*a"); f:close(); return b
end
local function sh(dir, cmd)
    local p = io.popen("cd " .. tmio.shell_quote(dir) .. " && " .. cmd .. " 2>/dev/null")
    local out = p:read("*a"); p:close()
    return (out:gsub("%s+$", ""))
end

-- ── citations: git:<sha> words in text ────────────────────────────────────

do
    local c = tmsha.citations_in("- [x] Done\n    > **Completed:** 2026-11-08 git:a1b2c3d\n    > **Notes:** was git:abc (too short), see git:0123456789abcdef0123456789abcdef01234567.\n")
    check("citations", "finds 7-40 hex digits after git:, with line numbers",
        #c == 2 and c[1].sha == "a1b2c3d" and c[1].line == 2 and #c[2].sha == 40 and c[2].line == 3)
    check("citations", "a longer word is not a citation", #tmsha.citations_in("git:a1b2c3dz and xgit:a1b2c3d") == 0)
end

-- ── remap_text: pure replacement ──────────────────────────────────────────

do
    local text = "git:a1b2c3d and git:a1b2c3d4e5 but not git:a1b2c3e or git:a1b2c3dffff1\n"
    local out, n = tmsha.remap_text(text, "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678", "fedcba9")
    check("remap", "replaces every abbreviation of the old commit, and nothing else",
        n == 2 and out == "git:fedcba9 and git:fedcba9 but not git:a1b2c3e or git:a1b2c3dffff1\n", out)
end

-- ── check and remap over a repository ─────────────────────────────────────

do
    local dir = string.format("/tmp/tm_sha_test_%d_%s", os.time(), tmio.unique_token())
    tmio.mkdir_p(dir .. "/.tasks/archive/2026")
    sh(dir, "git init -q -b main && git commit -q --allow-empty -m one")
    local main_sha = sh(dir, "git rev-parse --short HEAD")
    sh(dir, "git checkout -q -b side && git commit -q --allow-empty -m side && git checkout -q main")
    local side_sha = sh(dir, "git rev-parse --short side")
    local tasks = dir .. "/.tasks"
    write(tasks .. "/active.tm.md", "# S\n\n- [x] On main\n    > **Completed:** 2026-11-08 git:" .. main_sha .. "\n")
    write(tasks .. "/completed.tm.md", "# C\n\n- [x] On side\n    > **Completed:** 2026-11-08 git:" .. side_sha ..
        "\n    > **Notes:** follows git:" .. main_sha .. "\n")
    write(tasks .. "/archive/2026/2026-01.tm.md", "# A\n\n- [x] Lost\n    > **Completed:** 2026-01-02 git:deadbee\n")

    local problems = tmsha.check({ tasks_dir = tasks })
    check("check", "reports a sha that does not resolve, with file and line",
        #problems == 1 and problems[1].sha == "deadbee" and problems[1].reason == "does not resolve"
        and problems[1].path:match("2026%-01%.tm%.md$") and problems[1].line == 4)

    problems = tmsha.check({ tasks_dir = tasks, branch = "main" })
    check("check", "--branch also reports commits not reachable from it", #problems == 2
        and problems[1].sha == side_sha and problems[1].reason:find("not reachable from main", 1, true) ~= nil)
    local none, err = tmsha.check({ tasks_dir = tasks, branch = "nosuch" })
    check("check", "an unknown branch is an error", none == nil and err:find("nosuch", 1, true) ~= nil, err)

    local tm_abs = io.popen("realpath " .. script_dir .. "/../src/tm"):read("*l")
    local function tm(args)
        local p = io.popen(string.format("cd %s && lua %s %s 2>&1; echo __EXIT__$?", tmio.shell_quote(dir), tm_abs, args))
        local out = p:read("*a"); p:close()
        return out:gsub("__EXIT__%d+%s*$", ""), tonumber(out:match("__EXIT__(%d+)"))
    end
    local out, code = tm("check-shas")
    check("cli", "check-shas exits 1 and names the problem",
        code == 1 and out:find("git:deadbee does not resolve", 1, true) ~= nil, out)

    sh(dir, "git checkout -q main && git merge -q --squash side && git commit -q -m squashed")
    local new_sha = sh(dir, "git rev-parse --short HEAD")
    out, code = tm("remap " .. side_sha .. " " .. new_sha)
    check("cli", "remap replaces the citation and reports pairs and counts",
        code == 0 and read(tasks .. "/completed.tm.md"):find("git:" .. new_sha .. "\n", 1, true) ~= nil
        and out:find("git:" .. side_sha .. " -> git:" .. new_sha .. ": 1 citation", 1, true) ~= nil, out)
    out, code = tm("remap deadbee " .. new_sha .. " " .. main_sha)
    check("cli", "remap takes pairs, so an odd count is an error", code ~= 0, out)
    out, code = tm("remap deadbee 1234567")
    check("cli", "remap refuses a new sha that is not a commit", code ~= 0 and out:find("1234567", 1, true) ~= nil
        and read(tasks .. "/archive/2026/2026-01.tm.md"):find("git:deadbee", 1, true) ~= nil, out)
    out, code = tm("remap deadbee " .. main_sha)
    check("cli", "remap reaches the archive", code == 0 and read(tasks .. "/archive/2026/2026-01.tm.md"):find("git:" .. main_sha, 1, true) ~= nil, out)
    out, code = tm("check-shas --branch main")
    check("cli", "after remapping, check-shas is clean", code == 0 and out:find("resolve", 1, true) ~= nil, out)
    out, code = tm("remap 7777777 " .. main_sha)
    check("cli", "remapping a sha cited nowhere says so and exits 0", code == 0 and out:find("0 citations", 1, true) ~= nil, out)

    os.execute("rm -rf " .. tmio.shell_quote(dir))
end

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
