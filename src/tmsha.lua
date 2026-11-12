#!/usr/bin/env lua
-- tmsha.lua — `tm check-shas` and `tm remap`: keep git:<sha> citations in
-- the task files pointing at real commits after history is rewritten
-- (SPEC-TASKMARK-05 §5.2, §10.3).
--
--   tm check-shas [--branch REF] [--tasks-dir DIR]
--   tm remap OLD NEW [OLD NEW...] [--tasks-dir DIR]

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path

local tmconfig = require("tmconfig")
local tmio     = require("tmio")
local tmgit    = require("tmgit")
local tmid     = require("tmid")

local M = {}

-- A citation: `git:` and 7 to 40 hex digits, as a whole word.
local CITATION = "%f[%w]git:(%x+)%f[^%w]"

local function is_sha(s)
    return #s >= 7 and #s <= 40 and s:match("^%x+$") ~= nil
end

-- Whether a cited abbreviation and a given sha name the same commit as far
-- as the text can tell: one is a prefix of the other.
local function same_commit(a, b)
    a, b = a:lower(), b:lower()
    local n = math.min(#a, #b)
    return a:sub(1, n) == b:sub(1, n)
end

-- Every citation in `text`: { line, sha }, in order.
function M.citations_in(text)
    local out, n = {}, 0
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        n = n + 1
        for sha in line:gmatch(CITATION) do
            if is_sha(sha) then out[#out + 1] = { line = n, sha = sha } end
        end
    end
    return out
end

-- `text` with every citation of commit `old` (any abbreviation of it)
-- replaced by `git:<new>`. Returns the text and the number replaced.
function M.remap_text(text, old, new)
    local count = 0
    local out = text:gsub(CITATION, function(sha)
        if is_sha(sha) and same_commit(sha, old) then
            count = count + 1
            return "git:" .. new
        end
    end)
    return out, count
end

local function read(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function is_commit(dir, rev)
    return (tmgit.run(dir, "rev-parse", "--verify", "--quiet", rev .. "^{commit}"))
end

-- Citations that do not resolve to a commit in the repository holding the
-- task directory, or, with opts.branch, that are not reachable from it.
-- Returns problems { path, line, sha, reason }; or nil, reason.
function M.check(opts)
    opts = opts or {}
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local dir = cfg.tasks_dir
    if not tmgit.toplevel(dir) then return nil, dir .. " is not inside a git repository" end
    if opts.branch and not is_commit(dir, opts.branch) then
        return nil, "not a branch or commit in this repository: " .. opts.branch
    end

    local verdict = {}
    local function judge(sha)
        if verdict[sha] == nil then
            if not is_commit(dir, sha) then
                verdict[sha] = "does not resolve"
            elseif opts.branch and not tmgit.run(dir, "merge-base", "--is-ancestor", sha, opts.branch) then
                verdict[sha] = "is not reachable from " .. opts.branch
            else
                verdict[sha] = false
            end
        end
        return verdict[sha]
    end

    local problems, total = {}, 0
    for _, path in ipairs(tmid.task_files(cfg)) do
        for _, c in ipairs(M.citations_in(read(path) or "")) do
            total = total + 1
            local reason = judge(c.sha)
            if reason then
                problems[#problems + 1] = { path = path, line = c.line, sha = c.sha, reason = reason }
            end
        end
    end
    return problems, total
end

-- Replace citations of each old commit with its new one in every task
-- file, the archive included. opts: pairs { { old, new }, ... }, tasks_dir.
-- Every new sha must name a commit. Returns true, results { old, new,
-- count, files }; or false, reason.
function M.remap(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local dir = cfg.tasks_dir
    for _, pair in ipairs(opts.pairs) do
        for _, sha in ipairs(pair) do
            if not is_sha(sha) then return false, "not a 7-40 digit hex sha: " .. sha end
        end
        if not is_commit(dir, pair[2]) then return false, "not a commit in this repository: " .. pair[2] end
    end

    return tmio.with_lock(dir, function()
        local results = {}
        for i, pair in ipairs(opts.pairs) do results[i] = { old = pair[1], new = pair[2], count = 0, files = 0 } end
        for _, path in ipairs(tmid.task_files(cfg)) do
            local text = read(path)
            local changed = false
            for i, pair in ipairs(opts.pairs) do
                local n
                text, n = M.remap_text(text, pair[1], pair[2])
                if n > 0 then
                    results[i].count = results[i].count + n
                    results[i].files = results[i].files + 1
                    changed = true
                end
            end
            if changed then
                local ok, err = tmio.write_file_atomic(path, text)
                if not ok then return false, err end
            end
        end
        return true, results
    end)
end

local USAGE = {
    ["check-shas"] = "Usage: tm check-shas [--branch REF] [--tasks-dir DIR]",
    remap = "Usage: tm remap OLD NEW [OLD NEW...] [--tasks-dir DIR]",
}

local function plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

function M.run(subcmd, args)
    local opts, positionals = {}, {}
    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-h" or a == "--help" then
            print(USAGE[subcmd]); os.exit(0)
        elseif a == "--tasks-dir" or (a == "--branch" and subcmd == "check-shas") then
            if not args[i + 1] then tmio.die(a .. " requires an argument") end
            opts[a:sub(3):gsub("%-", "_")] = args[i + 1]
            i = i + 1
        elseif a:match("^%-") then
            tmio.die("Unknown option: " .. a .. "\n" .. USAGE[subcmd])
        else
            positionals[#positionals + 1] = a
        end
        i = i + 1
    end

    if subcmd == "check-shas" then
        if #positionals > 0 then tmio.die("Unexpected argument: " .. positionals[1] .. "\n" .. USAGE[subcmd]) end
        local problems, total = M.check(opts)
        if not problems then tmio.die(total) end
        for _, p in ipairs(problems) do
            print(string.format("%s:%d: git:%s %s", p.path, p.line, p.sha, p.reason))
        end
        if #problems > 0 then
            print(string.format("%s of %d do not hold.", plural(#problems, "citation"), total))
            os.exit(1)
        end
        print(string.format("All %s resolve%s.", plural(total, "git:<sha> citation"),
            opts.branch and (" and are reachable from " .. opts.branch) or ""))
        os.exit(0)
    end

    if #positionals == 0 or #positionals % 2 ~= 0 then
        tmio.die("tm remap takes OLD NEW pairs.\n" .. USAGE.remap)
    end
    local pairs_ = {}
    for j = 1, #positionals, 2 do pairs_[#pairs_ + 1] = { positionals[j], positionals[j + 1] } end
    local ok, results = M.remap({ pairs = pairs_, tasks_dir = opts.tasks_dir })
    if not ok then tmio.die("tm remap: " .. tostring(results)) end
    for _, r in ipairs(results) do
        print(string.format("git:%s -> git:%s: %s in %s", r.old, r.new,
            plural(r.count, "citation"), plural(r.files, "file")))
    end
    os.exit(0)
end

return M
