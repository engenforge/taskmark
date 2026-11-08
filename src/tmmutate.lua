#!/usr/bin/env lua
-- tmmutate.lua — task mutations and compact listings addressed by ephemeral
-- handles (SPEC-TASKMARK-04 tooling; handles are never written to a file).
--
-- Subcommands:
--   tm list [--pending|--all] [--tasks-dir DIR] [file...]
--   tm done <handle-or-pattern> [--git [REV]] [--file FILE] [--tasks-dir DIR]
--   tm move <handle-or-pattern> [--from FILE] [--to FILE] [--section SECTION] [--tasks-dir DIR]
--   tm add <task-text> [-p|--priority PRI] [--section SECTION] [--file FILE] [--tasks-dir DIR]
--
-- A handle is the shortest prefix (at least 4 hex digits) of a task's
-- tmscan.task_hash that is unique among the tasks of its file; `tm list`
-- prints it, and any longer prefix of the same hash resolves too.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path

local tmscan       = require("tmscan")
local tmconfig     = require("tmconfig")
local tmio         = require("tmio")
local tmsweep_core = require("tmsweep_core")
local tmgit        = require("tmgit")

local M = {}

M.MIN_HANDLE = 4

-- ── File and document helpers ─────────────────────────────────────────────

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return tmscan.lines_of(content), tmscan.detect_newline(content)
end

local function write_lines(path, lines, nl)
    lines = tmsweep_core.normalize_blank_lines(lines)
    return tmio.write_file_atomic(path, table.concat(lines, nl) .. nl)
end

local function dir_of(path)
    return path:match("^(.*)/[^/]+$") or "."
end

-- Canonical form of an existing directory (symlinks resolved), using only
-- `cd` and `pwd -P` -- no dependency on realpath(1).
local function canonical_dir(dir)
    return tmgit.realpath(dir) or dir
end

-- Canonical name of an existing file: symlinks in the name followed, then
-- its directory canonicalized.
local function canonical_file(path)
    local resolved = tmio.resolve_symlinks(path)
    return canonical_dir(dir_of(resolved)) .. "/" .. (resolved:match("([^/]+)$") or resolved)
end

-- Whether two existing paths name the same file. Either check suffices:
-- a missed match would move a task out of a file and then overwrite it.
local function same_file(a, b)
    if canonical_file(a) == canonical_file(b) then return true end
    local r = os.execute("test " .. tmio.shell_quote(a) .. " -ef " .. tmio.shell_quote(b) .. " 2>/dev/null")
    return r == true or r == 0
end

-- Run fn while holding the locks of every distinct directory in `dirs`
-- (compared canonically, so two spellings of one directory are one lock),
-- acquired in sorted order so two runs can never deadlock.
local function with_locks(dirs, fn)
    local seen, sorted = {}, {}
    for _, d in ipairs(dirs) do
        local c = canonical_dir(d)
        if not seen[c] then seen[c] = true; sorted[#sorted + 1] = c end
    end
    table.sort(sorted)
    local function nest(i)
        if i > #sorted then return fn() end
        return tmio.with_lock(sorted[i], nest, i + 1)
    end
    return nest(1)
end

-- Headings in document order: { line, level, text }.
local function headings(lines)
    local out = {}
    for i = 1, #lines do
        local kind, fields = tmscan.classify(lines[i])
        if kind == "heading" then
            out[#out + 1] = { line = i, level = fields.level, text = fields.text }
        end
    end
    return out
end

-- Where a new task block goes: at the end of the named heading's own
-- content (before the next heading of any level), or of the first
-- heading's when no section is named, or at the end of a heading-less
-- file. Returns the line index to insert before, or nil, reason.
local function insertion_point(lines, section)
    local hs = headings(lines)
    local target
    if section then
        for idx, h in ipairs(hs) do
            if h.text:lower() == section:lower() then target = idx break end
        end
        if not target then
            local names = {}
            for _, h in ipairs(hs) do names[#names + 1] = h.text end
            return nil, string.format("no section '%s' (sections: %s)", section,
                #names > 0 and table.concat(names, ", ") or "none")
        end
    elseif #hs > 0 then
        target = 1
    else
        return #lines + 1
    end
    local next_h = hs[target + 1]
    local stop = next_h and next_h.line - 1 or #lines
    -- Insert after the section's last non-blank line, so blank lines that
    -- separate it from the next heading stay below the new block.
    while stop > hs[target].line and lines[stop]:match("^%s*$") do stop = stop - 1 end
    return stop + 1
end

-- Splice `block` into `lines` before index `at`, separated by blank lines.
local function splice(lines, at, block)
    local out = {}
    for i = 1, at - 1 do out[#out + 1] = lines[i] end
    if #out > 0 then out[#out + 1] = "" end
    for _, l in ipairs(block) do out[#out + 1] = l end
    if at <= #lines then out[#out + 1] = "" end
    for i = at, #lines do out[#out + 1] = lines[i] end
    return out
end

-- The last line of a task's block: its task line plus payload, without the
-- trailing blank lines tmscan counts into the payload range.
local function block_end(lines, task)
    if task.payload_start and task.payload_end then
        for i = task.payload_end, task.payload_start, -1 do
            if not lines[i]:match("^%s*$") then return i end
        end
    end
    return task.line
end

-- ── Handles and task lookup ───────────────────────────────────────────────

-- Shortest unique handle (>= MIN_HANDLE hex digits) for each task, keyed by
-- task record. Tasks with identical summaries share a hash; they get the
-- full hash and can only be told apart by editing one of them.
function M.handles(tasks)
    local out = {}
    for _, t in ipairs(tasks) do
        local len = M.MIN_HANDLE
        for _, o in ipairs(tasks) do
            if o ~= t and o.hash ~= t.hash then
                local common = 0
                while common < #t.hash and t.hash:sub(common + 1, common + 1) == o.hash:sub(common + 1, common + 1) do
                    common = common + 1
                end
                if common + 1 > len then len = common + 1 end
            end
        end
        out[t] = t.hash:sub(1, len)
    end
    return out
end

-- Find a task in `tasks` by hash prefix (>= MIN_HANDLE hex digits, with or
-- without [brackets]) or case-insensitive substring of its summary.
-- Returns task; or nil, "ambiguous_hash" | "ambiguous_pattern", candidates;
-- or nil, "not_found".
function M.find_task(tasks, query)
    if not query then return nil, "not_found" end
    local q = query:gsub("^%s*%[", ""):gsub("%]%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return nil, "not_found" end

    if #q >= M.MIN_HANDLE and q:match("^%x+$") then
        local qh = q:lower()
        local matches = {}
        for _, t in ipairs(tasks) do
            if t.hash:sub(1, #qh) == qh then matches[#matches + 1] = t end
        end
        if #matches == 1 then return matches[1] end
        if #matches > 1 then return nil, "ambiguous_hash", matches end
        -- No hash matched: a hex-looking word may still be a pattern.
    end

    local ql = q:lower()
    local matches = {}
    for _, t in ipairs(tasks) do
        if t.summary:lower():find(ql, 1, true) then matches[#matches + 1] = t end
    end
    if #matches == 1 then return matches[1] end
    if #matches > 1 then return nil, "ambiguous_pattern", matches end
    return nil, "not_found"
end

-- Candidate lines for an ambiguity error, using handles unique in the file.
function M.format_candidates(matches, handles)
    local out = {}
    for _, t in ipairs(matches) do
        out[#out + 1] = string.format("  [%s] %s %s (line %d)",
            handles and handles[t] or t.hash, t.done and "[x]" or "[ ]", t.summary, t.line)
    end
    return table.concat(out, "\n")
end

-- Compact one-line-per-task listing of a file. opts.filter: "pending"
-- (default) or "all". Returns the lines, or nil, reason.
function M.format_list(file_or_lines, opts)
    opts = opts or {}
    local lines = file_or_lines
    if type(file_or_lines) == "string" then
        lines = read_file(file_or_lines)
        if not lines then return nil, "no such file: " .. file_or_lines end
    end
    local tasks = tmscan.tasks(lines)
    local handles = M.handles(tasks)
    local out = {}
    for _, t in ipairs(tasks) do
        if not t.done then
            out[#out + 1] = string.format("[%s] %s", handles[t], t.summary)
        elseif opts.filter == "all" then
            out[#out + 1] = string.format("[%s] [x] %s", handles[t], t.summary)
        end
    end
    return out
end

-- ── tm done ───────────────────────────────────────────────────────────────

local FIELD = "^    > %*%*[A-Za-z][A-Za-z0-9_%-]*:%*%*"

-- Mark a pending task done and stamp its Completed field. opts: file |
-- tasks_dir, query, git_sha, date (default: today, local time).
-- Returns true, task; or false, reason, detail.
function M.done(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local file = opts.file or cfg.active_path

    return tmio.with_lock(dir_of(file), function()
        local lines, nl = read_file(file)
        if not lines then return false, "no such file: " .. file end

        local tasks = tmscan.tasks(lines)
        local handles = M.handles(tasks)
        local pending = {}
        for _, t in ipairs(tasks) do
            if not t.done then pending[#pending + 1] = t end
        end

        local task, err, candidates = M.find_task(pending, opts.query)
        if not task then
            if err == "not_found" then
                local done_match = M.find_task(tasks, opts.query)
                if done_match then return false, "already_completed", { task = done_match, handles = handles } end
            end
            return false, err, { candidates = candidates, handles = handles }
        end

        lines[task.line] = lines[task.line]:gsub("^%- %[ %]", "- [x]", 1)

        local stamp = "    > **Completed:** " .. (opts.date or os.date("%Y-%m-%d"))
        if opts.git_sha then stamp = stamp .. " git:" .. opts.git_sha end

        local last = block_end(lines, task)
        -- An existing Completed field, ignoring fenced code: a fenced
        -- example of a Completed line is content, not the task's field.
        local existing
        for i, _, _, _, _, fence_open in tmscan.iter(lines) do
            if i > last then break end
            if i > task.line and not fence_open and lines[i]:match("^    > %*%*Completed:%*%*") then
                existing = i
                break
            end
        end

        if existing then
            lines[existing] = stamp
        else
            -- Join the leading run of labeled fields (§4.4.2): directly
            -- beneath the task line, past any fields and their `    > `
            -- continuation lines.
            local at = task.line + 1
            while at <= last and (lines[at]:match(FIELD) or
                    (at > task.line + 1 and lines[at]:match("^    > ") and lines[at - 1]:match("^    > "))) do
                at = at + 1
            end
            table.insert(lines, at, stamp)
            -- Freeform content directly beneath a field needs a blank line (V11).
            local after = lines[at + 1]
            if at == task.line + 1 and after and at + 1 <= last + 1 and after:match("^    ")
                and not after:match("^    > ") then
                table.insert(lines, at + 1, "")
            end
        end

        local ok, werr = write_lines(file, lines, nl)
        if not ok then return false, werr end
        return true, task, handles
    end)
end

-- ── tm move ───────────────────────────────────────────────────────────────

-- Move a task (with its payload) from one document to another, or to
-- another section of the same document. The destination is written first,
-- so an interrupted move leaves a duplicate rather than losing the task.
function M.move(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local from = opts.from or cfg.future_path
    local to = opts.to or cfg.active_path

    return with_locks({ dir_of(from), dir_of(to) }, function()
        local src, src_nl = read_file(from)
        if not src then return false, "no such file: " .. from end
        local dest, dest_nl = read_file(to)
        if not dest then return false, "no such file: " .. to end
        local same = same_file(from, to)

        local tasks = tmscan.tasks(src)
        local handles = M.handles(tasks)
        local task, err, candidates = M.find_task(tasks, opts.query)
        if not task then return false, err, { candidates = candidates, handles = handles } end

        local last = block_end(src, task)
        local block, rest = {}, {}
        for i = 1, #src do
            if i >= task.line and i <= last then block[#block + 1] = src[i]
            else rest[#rest + 1] = src[i] end
        end

        if same then
            local at, aerr = insertion_point(rest, opts.section)
            if not at then return false, aerr .. " in " .. to end
            local ok, werr = write_lines(to, splice(rest, at, block), dest_nl)
            if not ok then return false, werr end
            return true, task, handles
        end

        local at, aerr = insertion_point(dest, opts.section)
        if not at then return false, aerr .. " in " .. to end
        local ok, werr = write_lines(to, splice(dest, at, block), dest_nl)
        if not ok then return false, werr end
        ok, werr = write_lines(from, rest, src_nl)
        if not ok then return false, werr end
        return true, task, handles
    end)
end

-- ── tm add ────────────────────────────────────────────────────────────────

-- Add a pending task to an existing document. opts: text, priority,
-- section, file | tasks_dir. Returns true, task-ish; or false, reason.
function M.add(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local file = opts.file or cfg.active_path

    local text = tmscan.task_summary(opts.text or "")
    if text == "" then return false, "empty task text" end
    if opts.priority then
        local pri = opts.priority:match("^%(?([A-Za-z])%)?$")
        if not pri then return false, "priority must be a single letter A-Z: " .. opts.priority end
        if not text:match("^%([A-Z]%) ") then text = "(" .. pri:upper() .. ") " .. text end
    end
    local task_line = "- [ ] " .. text

    return tmio.with_lock(dir_of(file), function()
        local lines, nl = read_file(file)
        if not lines then return false, "no such file: " .. file end
        local at, aerr = insertion_point(lines, opts.section)
        if not at then return false, aerr .. " in " .. file end
        local new_lines = tmsweep_core.normalize_blank_lines(splice(lines, at, { task_line }))
        local ok, werr = write_lines(file, new_lines, nl)
        if not ok then return false, werr end

        local after = tmscan.tasks(new_lines)
        local handles = M.handles(after)
        for _, t in ipairs(after) do
            if t.summary == text then return true, t, handles end
        end
        return true, { hash = tmscan.task_hash(task_line), summary = text }, nil
    end)
end

-- ── CLI ───────────────────────────────────────────────────────────────────

local USAGE = {
    list = "Usage: tm list [--pending|--all] [--tasks-dir DIR] [file...]",
    done = "Usage: tm done [options] [--] <handle-or-pattern>   (options: --git [REV], --file FILE, --tasks-dir DIR)",
    move = "Usage: tm move [options] [--] <handle-or-pattern>   (options: --from FILE, --to FILE, --section SECTION, --tasks-dir DIR)",
    add  = "Usage: tm add [options] [--] <task-text>   (options: -p|--priority PRI, --section SECTION, --file FILE, --tasks-dir DIR)",
}

local VALUE_OPTS = {
    ["--tasks-dir"] = "tasks_dir", ["--file"] = "file", ["--section"] = "section",
    ["-p"] = "priority", ["--priority"] = "priority", ["--from"] = "from", ["--to"] = "to",
}

-- Short SHA of a commit-ish, verified to exist; nil if it does not resolve.
local function resolve_git_sha(rev)
    local p = io.popen("git rev-parse --verify --quiet --short " ..
        tmio.shell_quote((rev or "HEAD") .. "^{commit}") .. " 2>/dev/null")
    local out = p and p:read("*l")
    if p then p:close() end
    if out and out:match("^%x%x%x%x%x%x%x+$") then return out end
    return nil
end

local function handle_of(task, handles)
    return handles and handles[task] or task.hash:sub(1, M.MIN_HANDLE)
end

-- Turn a failed lookup/mutation into a message and exit.
local function report_failure(query, reason, detail)
    detail = detail or {}
    if reason == "ambiguous_hash" or reason == "ambiguous_pattern" then
        tmio.die(string.format("Ambiguous %s '%s' matches %d tasks:\n%s\n%s",
            reason == "ambiguous_hash" and "handle" or "pattern", query, #detail.candidates,
            M.format_candidates(detail.candidates, detail.handles),
            "Use one of the handles shown, or a more specific pattern."))
    elseif reason == "already_completed" then
        tmio.die(string.format("Task is already completed: [%s] %s",
            handle_of(detail.task, detail.handles), detail.task.summary))
    elseif reason == "not_found" then
        tmio.die(string.format("No task found matching '%s'.", query))
    end
    tmio.die(tostring(reason))
end

function M.run(subcmd, args)
    args = args or {}
    local opts, positionals = {}, {}
    local filter = "pending"
    local git_flag, git_rev, git_at = false, nil, nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--" then
            -- End of options: everything after is task text or a pattern,
            -- even when it starts with '-'.
            for j = i + 1, #args do positionals[#positionals + 1] = args[j] end
            break
        elseif VALUE_OPTS[a] then
            if not args[i + 1] then tmio.die(a .. " requires an argument") end
            opts[VALUE_OPTS[a]] = args[i + 1]
            i = i + 1
        elseif a == "--pending" then
            filter = "pending"
        elseif a == "--all" then
            filter = "all"
        elseif a == "--git" then
            git_flag, git_at = true, #positionals + 1
        elseif a:match("^%-%-git=") then
            git_flag, git_rev = true, a:sub(7)
        elseif a == "-h" or a == "--help" then
            print(USAGE[subcmd])
            os.exit(0)
        elseif a:match("^%-") then
            tmio.die("Unknown option: " .. a .. "\n" .. USAGE[subcmd])
        else
            positionals[#positionals + 1] = a
        end
        i = i + 1
    end

    -- `--git` takes an optional REV: the word right after it is the REV
    -- exactly when the command would otherwise have one positional too many
    -- (`tm done --git abc1234 Fix` and `tm done Fix --git abc1234` both
    -- name a rev; `tm done --git Fix` and `tm done Fix --git` use HEAD).
    if git_flag and git_at and subcmd == "done" and #positionals >= 2 and positionals[git_at] then
        git_rev = table.remove(positionals, git_at)
    end
    if git_flag and subcmd ~= "done" then
        tmio.die("--git applies only to tm done\n" .. USAGE[subcmd])
    end

    if subcmd == "list" then
        local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
        local files = #positionals > 0 and positionals or { cfg.active_path }
        for idx, f in ipairs(files) do
            local items, err = M.format_list(f, { filter = filter })
            if not items then tmio.die(err) end
            if #files > 1 then
                if idx > 1 then print("") end
                print("== " .. f)
            end
            for _, item in ipairs(items) do print(item) end
        end
        os.exit(0)
    end

    if subcmd == "add" then
        if #positionals == 0 then tmio.die("tm add requires task text.\n" .. USAGE.add) end
        local ok, res, handles = M.add({
            text = table.concat(positionals, " "), priority = opts.priority,
            section = opts.section, file = opts.file, tasks_dir = opts.tasks_dir,
        })
        if not ok then tmio.die("Failed to add task: " .. tostring(res)) end
        print(string.format("Added: [%s] %s", handle_of(res, handles), res.summary))
        os.exit(0)
    end

    if #positionals == 0 then
        tmio.die("tm " .. subcmd .. " requires a task handle or pattern.\n" .. USAGE[subcmd])
    elseif #positionals > 1 then
        tmio.die("Unexpected argument: " .. positionals[2] ..
            " (quote a multi-word pattern)\n" .. USAGE[subcmd])
    end
    local query = positionals[1]

    if subcmd == "done" then
        local git_sha
        if git_flag then
            git_sha = resolve_git_sha(git_rev)
            if not git_sha then tmio.die("Not a commit in this repository: " .. (git_rev or "HEAD")) end
        end
        local ok, res, detail = M.done({
            file = opts.file, tasks_dir = opts.tasks_dir, query = query, git_sha = git_sha,
        })
        if not ok then report_failure(query, res, detail) end
        print(string.format("Completed: [%s] %s", handle_of(res, detail), res.summary))
        os.exit(0)
    end

    if subcmd == "move" then
        local ok, res, detail = M.move({
            query = query, from = opts.from or opts.file, to = opts.to,
            section = opts.section, tasks_dir = opts.tasks_dir,
        })
        if not ok then report_failure(query, res, detail) end
        print(string.format("Moved: [%s] %s", handle_of(res, detail), res.summary))
        os.exit(0)
    end
end

return M
