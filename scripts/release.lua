#!/usr/bin/env lua
-- scripts/release.lua — the steps behind `make pre-release VERSION=X.Y.Z`.
--
--   lua scripts/release.lua check X.Y.Z     validate; change nothing
--   lua scripts/release.lua prepare X.Y.Z   write VERSION and date the
--                                           CHANGELOG's [Unreleased] section
--
-- `make pre-release` runs `check`, then the release checks (make test, which
-- includes make man-check, by default), then `prepare`. It never commits,
-- tags, signs, or pushes: the maintainer reviews the two edited files and
-- does that by hand; the commands are printed at the end.
-- Run from the repository root.

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function run(cmd)
    local p = io.popen(cmd .. " 2>&1; echo __EXIT__$?")
    local out = p:read("*a")
    p:close()
    local code = tonumber(out:match("__EXIT__(%d+)%s*$")) or 1
    return code == 0, (out:gsub("__EXIT__%d+%s*$", ""):gsub("%s+$", ""))
end

local function die(msg)
    io.stderr:write("pre-release: " .. msg .. "\n")
    os.exit(1)
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write(path, s)
    local f = io.open(path, "w")
    if not f then die("cannot write " .. path) end
    f:write(s)
    f:close()
end

local function parse(v)
    local a, b, c = (v or ""):match("^(%d+)%.(%d+)%.(%d+)$")
    if a then return { tonumber(a), tonumber(b), tonumber(c) } end
end

local function newer(x, y)
    for i = 1, 3 do
        if x[i] ~= y[i] then return x[i] > y[i] end
    end
    return false
end

-- The CHANGELOG with its [Unreleased] heading located; dies when the
-- section is missing or has nothing in it.
local function unreleased(changelog)
    local s = read(changelog) or die("cannot read " .. changelog)
    local head = s:find("## [Unreleased]\n", 1, true)
    if not head then die(changelog .. " has no '## [Unreleased]' section") end
    local body_start = head + #"## [Unreleased]\n"
    local next_head = s:find("\n## %[", body_start) or #s
    local body = s:sub(body_start, next_head)
    if not body:gsub("%-%-%-", ""):find("%S") then
        die("the [Unreleased] section of " .. changelog .. " is empty: nothing to release")
    end
    return s, head
end

local function check(version)
    if not version or version == "" then die("usage: make pre-release VERSION=X.Y.Z") end
    local new = parse(version) or die("not an X.Y.Z version: " .. version)
    local current_text = (read("VERSION") or ""):match("^%s*(%S+)")
    local current = parse(current_text) or die("VERSION does not hold an X.Y.Z version")
    if not newer(new, current) then
        die(string.format("%s is not newer than the current version %s", version, current_text))
    end
    local ok, status = run("git status --porcelain --untracked-files=no")
    if not ok then die("not a git repository: " .. status) end
    if status ~= "" then die("the working tree has uncommitted changes:\n" .. status) end
    if run("git rev-parse -q --verify " .. q("refs/tags/v" .. version)) then
        die("tag v" .. version .. " already exists")
    end
    unreleased("CHANGELOG.md")
end

local function prepare(version)
    check(version)
    local s, head = unreleased("CHANGELOG.md")
    local dated = string.format("## [Unreleased]\n\n---\n\n## [%s] - %s\n", version, os.date("%Y-%m-%d"))
    write("CHANGELOG.md", s:sub(1, head - 1) .. dated .. s:sub(head + #"## [Unreleased]\n"))
    write("VERSION", version .. "\n")

    local tag = "v" .. version
    local function step(cmd, note)
        return note and string.format("  %-46s # %s", cmd, note) or "  " .. cmd
    end
    print(table.concat({
        string.format("Prepared %s: VERSION bumped and the CHANGELOG's [Unreleased] section dated.", version),
        "Nothing was committed or tagged.",
        "",
        "Next steps:",
        step("git diff", "review VERSION and CHANGELOG.md"),
        step("git commit -am " .. q("Release " .. version)),
        step("git tag -s " .. tag .. " -m " .. q("Taskmark " .. tag), "or -a for an unsigned tag"),
        step("make dist dist-bin", "build/dist/taskmark-" .. version .. "*.tar.xz + SHA256SUMS"),
        step("git push <remote> main " .. tag, "for each remote"),
        step("upload build/dist/* to the " .. tag .. " release page"),
        "",
        "To abandon it instead: git checkout -- VERSION CHANGELOG.md",
    }, "\n"))
end

local cmd, version = arg[1], arg[2]
if cmd == "check" then
    check(version)
elseif cmd == "prepare" then
    prepare(version)
else
    die("usage: lua scripts/release.lua check|prepare X.Y.Z")
end
