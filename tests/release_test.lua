#!/usr/bin/env lua
-- tests/release_test.lua — release tooling: `make pre-release`, the tag/VERSION
-- consistency check in `make dist`, and tm's version fallback.
--
-- Each case runs in a throwaway git repository holding a copy of the
-- current working tree, so nothing here touches this repository's history.

-- Run hermetically (see tests/tmsync_test.lua): no global, system, or
-- environment-injected git configuration -- in particular no signing.
package.path = ((arg[0] or ""):match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
require("testgit").isolate()

local script_dir = (arg[0] or "./tests/release_test.lua"):match("^(.*)/[^/]+$") or "."
local root = io.popen("cd " .. script_dir .. "/.. && pwd"):read("*l")

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

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(cmd)
    local p = io.popen(cmd .. " 2>&1; echo __EXIT__$?")
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("__EXIT__(%d+)%s*$")) or -1
    return out:gsub("__EXIT__%d+%s*$", ""), code
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, s)
    local f = assert(io.open(path, "w"))
    f:write(s)
    f:close()
end

-- A git repository holding the working tree's tracked and untracked
-- (non-ignored) files, committed, with VERSION and CHANGELOG.md replaced
-- by small known contents.
local function scratch_repo(changelog)
    local dir = run("mktemp -d"):gsub("%s+$", "")
    run(string.format("cd %s && git ls-files -co --exclude-standard -z | xargs -0 tar -cf - | (cd %s && tar -xf -)", q(root), q(dir)))
    write(dir .. "/VERSION", "0.3.0\n")
    write(dir .. "/CHANGELOG.md", changelog or table.concat({
        "# Changelog", "", "---", "",
        "## [Unreleased]", "", "### Added", "- Something new.", "", "---", "",
        "## [0.3.0] - 2026-10-27", "", "### Changed", "- Older change.", "",
    }, "\n"))
    run(string.format("cd %s && git init -q -b main && git add -A && git commit -qm base", q(dir)))
    return dir
end

-- Runs make in a scratch repository with an empty MAKEFLAGS, so variables
-- given to an enclosing make (`make test VERSION=...`, or the checks run by
-- `make pre-release VERSION=...`) cannot leak in and change what is tested.
-- The quick check-modules stands in for the full test suite as the release
-- check; args come last, so a case can override it.
local function make(dir, args)
    return run(string.format("cd %s && MAKEFLAGS= MFLAGS= MAKELEVEL= make --no-print-directory RELEASE_CHECKS=check-modules %s",
        q(dir), args))
end

local function cleanup(dir) run("rm -rf " .. q(dir)) end

-- ── tm's version fallback ─────────────────────────────────────────────────

do
    -- With no VERSION file anywhere it looks, tm says so rather than
    -- reporting a stale hard-coded number.
    local dir = run("mktemp -d"):gsub("%s+$", "")
    run(string.format("mkdir -p %s/bin && cp %s/src/tm %s/src/*.lua %s/bin/", q(dir), q(root), q(root), q(dir)))
    local out = run(string.format("lua %s/bin/tm version", q(dir)))
    check("version", "no VERSION file: tm reports 'unknown'", out:match("^tm unknown%s*$") ~= nil, out)
    cleanup(dir)
end

-- Everything below exercises maintainer tooling (`make pre-release`, and
-- `make dist`, which builds from git HEAD): it needs git and a git checkout
-- of the source, so it is skipped -- and reported -- in a release tarball or
-- without git.
local function in_git_checkout()
    local _, code = run(string.format("cd %s && git rev-parse --is-inside-work-tree", q(root)))
    return code == 0
end
if not in_git_checkout() then
    print("[SKIP] pre-release, dist: needs git and a git checkout of the source")
    print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
    os.exit(failed > 0 and 1 or 0)
end

local function state(dir)
    return run(string.format("cd %s && git rev-parse HEAD && git tag && cat VERSION CHANGELOG.md", q(dir)))
end

-- ── make pre-release ──────────────────────────────────────────────────────

do
    local dir = scratch_repo()
    local head = run(string.format("cd %s && git rev-parse HEAD", q(dir)))
    local out, code = make(dir, "pre-release VERSION=0.4.0")
    local today = os.date("%Y-%m-%d")
    check("pre-release", "make pre-release VERSION=0.4.0 succeeds", code == 0, out)
    check("pre-release", "VERSION is bumped", read(dir .. "/VERSION") == "0.4.0\n", read(dir .. "/VERSION"))
    local cl = read(dir .. "/CHANGELOG.md") or ""
    check("pre-release", "CHANGELOG: fresh empty [Unreleased], then the dated release",
        cl:find("## [Unreleased]\n\n---\n\n## [0.4.0] - " .. today .. "\n\n### Added\n- Something new.", 1, true) ~= nil, cl)
    check("pre-release", "nothing is committed", run(string.format("cd %s && git rev-parse HEAD", q(dir))) == head)
    check("pre-release", "nothing is tagged", run(string.format("cd %s && git tag", q(dir))):gsub("%s+", "") == "")
    local status = run(string.format("cd %s && git status --porcelain", q(dir)))
    check("pre-release", "only VERSION and CHANGELOG.md are modified, unstaged",
        status == " M CHANGELOG.md\n M VERSION\n", status)
    check("pre-release", "prints the review, commit, and tag steps",
        out:find("git diff", 1, true) and out:find("git commit -am 'Release 0.4.0'", 1, true)
        and out:find("git tag -s v0.4.0", 1, true) and out:find("make dist dist-bin", 1, true) ~= nil, out)

    -- Running it again before committing is refused (the tree is dirty).
    local before = state(dir)
    out, code = make(dir, "pre-release VERSION=0.4.0")
    check("pre-release", "a second run before committing is refused, changing nothing",
        code ~= 0 and state(dir) == before, out)

    -- The maintainer commits and tags by hand; the tag builds with plain
    -- version names, and preparing the same version again is refused.
    run(string.format("cd %s && git commit -qam 'Release 0.4.0' && git tag -a -m 'Taskmark v0.4.0' v0.4.0", q(dir)))
    out, code = make(dir, "dist")
    check("pre-release", "make dist on the hand-made tag builds taskmark-0.4.0.tar.xz",
        code == 0 and read(dir .. "/build/dist/taskmark-0.4.0.tar.xz") ~= nil, out)
    out, code = make(dir, "pre-release VERSION=0.4.0")
    check("pre-release", "preparing the current version again is refused", code ~= 0 and out:find("0.4.0", 1, true) ~= nil, out)
    cleanup(dir)
end

do
    -- The release argument stops at `make pre-release`: the checks it runs
    -- see the VERSION file's value, just as a plain `make test` would.
    local dir = scratch_repo()
    local f = assert(io.open(dir .. "/Makefile", "a"))
    f:write('\nprobe-version:\n\t@echo "checks see VERSION=$(VERSION)"\n')
    f:close()
    run(string.format("cd %s && git commit -qam probe", q(dir)))
    local out, code = make(dir, "pre-release VERSION=0.4.0 RELEASE_CHECKS=probe-version")
    check("pre-release", "checks see VERSION from the file, not the argument",
        code == 0 and out:find("checks see VERSION=0.3.0", 1, true) ~= nil and read(dir .. "/VERSION") == "0.4.0\n", out)
    cleanup(dir)
end

do
    -- Failing checks stop it before any file is touched.
    local dir = scratch_repo()
    local before = state(dir)
    local out, code = make(dir, "pre-release VERSION=0.4.0 RELEASE_CHECKS=no-such-target")
    check("pre-release", "failing checks: refused, nothing changed", code ~= 0 and state(dir) == before, out)
    cleanup(dir)
end

do
    -- A newer version whose tag already exists (made by hand, say) is refused.
    local dir = scratch_repo()
    run(string.format("cd %s && git tag -a -m earlier v0.4.0", q(dir)))
    local out, code = make(dir, "pre-release VERSION=0.4.0")
    check("pre-release", "an existing tag is refused", code ~= 0 and out:find("tag v0.4.0 already exists", 1, true) ~= nil, out)
    check("pre-release", "VERSION untouched after the refusal", read(dir .. "/VERSION") == "0.3.0\n")
    cleanup(dir)
end

do
    -- Refusals leave the repository exactly as it was.
    local cases = {
        { name = "missing VERSION argument", args = "pre-release" },
        { name = "malformed version", args = "pre-release VERSION=0.4" },
        { name = "version not above the current one", args = "pre-release VERSION=0.2.9" },
        { name = "dirty working tree", args = "pre-release VERSION=0.4.0", dirty = true },
        { name = "empty [Unreleased] section", args = "pre-release VERSION=0.4.0",
          changelog = "# Changelog\n\n## [Unreleased]\n\n---\n\n## [0.3.0] - 2026-10-27\n\n- Older.\n" },
        { name = "no [Unreleased] section", args = "pre-release VERSION=0.4.0",
          changelog = "# Changelog\n\n## [0.3.0] - 2026-10-27\n\n- Older.\n" },
    }
    for _, c in ipairs(cases) do
        local dir = scratch_repo(c.changelog)
        if c.dirty then write(dir .. "/README.md", "local edit\n") end
        local before = state(dir)
        local out, code = make(dir, c.args)
        check("pre-release", "refuses: " .. c.name, code ~= 0 and state(dir) == before, out)
        cleanup(dir)
    end
end

-- ── make dist: tag and VERSION must agree ─────────────────────────────────

do
    local dir = scratch_repo()
    run(string.format("cd %s && git tag -a -m mismatched v9.9.9", q(dir)))
    local out, code = make(dir, "dist")
    check("dist", "HEAD tagged v9.9.9 with VERSION 0.3.0 is refused",
        code ~= 0 and out:find("v9.9.9", 1, true) ~= nil and out:find("0.3.0", 1, true) ~= nil, out)
    out, code = make(dir, "dist-bin")
    check("dist", "dist-bin is refused the same way", code ~= 0, out)
    cleanup(dir)
end

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
