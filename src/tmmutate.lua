#!/usr/bin/env lua
-- tmmutate.lua — task mutations and compact listings addressed by handle
-- (SPEC-TASKMARK-06 tooling).
--
-- Subcommands:
--   tm list [--pending|--all] [--not TAG]... [TAG...] [--tasks-dir DIR] [file...]
--   tm next [--not TAG]... [TAG...] [--file FILE] [--tasks-dir DIR]
--   tm id [--tasks-dir DIR] [file...]
--   tm done <handle-or-pattern> [--git [REV]] [--file FILE] [--tasks-dir DIR]
--   tm move <handle-or-pattern> [--from FILE] [--to FILE] [--section SECTION] [--tasks-dir DIR]
--   tm add <task-text> [-p|--priority PRI] [--section SECTION] [--file FILE] [--tasks-dir DIR]
--   tm payload <handle-or-pattern> [--append|--replace] [--file FILE] [--tasks-dir DIR]
--
-- A task's handle is its identifier (§4.3.3, `id:k7q2x` on the task line)
-- when it has one. Otherwise it is ephemeral and never written to a file:
-- the shortest prefix (at least 4 hex digits) of the task's
-- tmscan.task_hash that is unique among the tasks of its file. `tm list`
-- prints either, and any longer prefix of the same hash resolves too.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path

local tmscan       = require("tmscan")
local tmconfig     = require("tmconfig")
local tmio         = require("tmio")
local tmsweep_core = require("tmsweep_core")
local tmgit        = require("tmgit")
local tmid         = require("tmid")
local tmval        = require("tmval")

local M = {}

M.MIN_HANDLE = 4

-- ── File and document helpers ─────────────────────────────────────────────

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

local function read_file(path, warned)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    local lines = tmscan.lines_of(content)
    tmio.warn_indented_tasks(path, lines, warned, warned and canonical_file(path))
    return lines, tmscan.detect_newline(content)
end

local function write_lines(path, lines, nl)
    lines = tmsweep_core.normalize_blank_lines(lines)
    return tmio.write_file_atomic(path, table.concat(lines, nl) .. nl)
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

-- Where a task block goes in `lines`: directly above the task named by
-- opts.before, directly below the block of the task named by opts.after
-- (both crossing headings freely), or else as for insertion_point.
-- Returns the line index to insert before; or nil, reason, detail, where
-- detail.query is the anchor that failed to resolve.
local function placement(lines, opts)
    local anchor = opts.before or opts.after
    if not anchor then
        local at, err = insertion_point(lines, opts.section)
        return at, err
    end
    if opts.before and opts.after then return nil, "give --before or --after, not both" end
    if opts.section then return nil, "--before/--after place the task exactly; drop --section" end
    local tasks = tmscan.tasks(lines)
    local task, err, candidates = M.find_task(tasks, anchor)
    if not task then return nil, err, { candidates = candidates, handles = M.handles(tasks), query = anchor } end
    if opts.before then return task.line end
    return block_end(lines, task) + 1
end

-- ── Handles and task lookup ───────────────────────────────────────────────

-- The handle of each task, keyed by task record: its identifier when it
-- has one that no other task of the file shares, else the shortest unique
-- prefix (>= MIN_HANDLE hex digits) of its hash. Tasks with identical
-- summaries share a hash; they get the full hash and can only be told
-- apart by editing one of them.
function M.handles(tasks)
    local out = {}
    local id_count = {}
    for _, t in ipairs(tasks) do
        local id = tmid.of(t.summary)
        if id then id_count[id] = (id_count[id] or 0) + 1 end
    end
    for _, t in ipairs(tasks) do
        local id = tmid.of(t.summary)
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
        out[t] = (id and id_count[id] == 1) and id or t.hash:sub(1, len)
    end
    return out
end

-- Find a task in `tasks` by identifier (with or without its `id:` prefix),
-- hash prefix (>= MIN_HANDLE hex digits), or case-insensitive substring of
-- its summary; a handle may be given in [brackets]. An identifier carried
-- by several tasks is ambiguous, like a shared hash prefix.
-- Returns task; or nil, "ambiguous_hash" | "ambiguous_pattern", candidates;
-- or nil, "not_found".
function M.find_task(tasks, query)
    if not query then return nil, "not_found" end
    local q = query:gsub("^%s*%[", ""):gsub("%]%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return nil, "not_found" end

    local id_matches = {}
    local q_id = q:gsub("^" .. tmid.PREFIX, "")
    for _, t in ipairs(tasks) do
        if tmid.of(t.summary) == q_id then id_matches[#id_matches + 1] = t end
    end
    if #id_matches == 1 then return id_matches[1] end
    if #id_matches > 1 then return nil, "ambiguous_hash", id_matches end

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

-- Whether a task line carries every tag in `tags` and none in `not_tags`.
-- A tag is matched as a whole word anywhere on the line (§4.3.2).
local function has_tags(summary, tags, not_tags)
    local words = {}
    for word in summary:gmatch("%S+") do words[word] = true end
    for _, tag in ipairs(tags or {}) do
        if not words[tag] then return false end
    end
    for _, tag in ipairs(not_tags or {}) do
        if words[tag] then return false end
    end
    return true
end

-- Compact one-line-per-task listing of a file. opts.filter: "pending"
-- (default) or "all", which also shows each task's checkbox; opts.tags /
-- opts.not_tags: tags a task must / must not carry; opts.claim_filter:
-- "claimed" or "unclaimed". Returns the lines, or nil, reason.
function M.format_list(file_or_lines, opts)
    opts = opts or {}
    local lines = file_or_lines
    if type(file_or_lines) == "string" then
        lines = read_file(file_or_lines, opts.warned)
        if not lines then return nil, "no such file: " .. file_or_lines end
    end
    local tasks = tmscan.tasks(lines)
    local handles = M.handles(tasks)
    local out = {}
    for _, t in ipairs(tasks) do
        local claimed
        if not t.done then
            local _, _, val = tmid.field(lines, t, "Claimed")
            claimed = val
        end
        local claim_ok = true
        if opts.claim_filter == "claimed" then
            claim_ok = not t.done and claimed ~= nil
        elseif opts.claim_filter == "unclaimed" then
            claim_ok = not t.done and claimed == nil
        end
        if not claim_ok or not has_tags(t.summary, opts.tags, opts.not_tags) then
            -- filtered out
        elseif opts.filter == "all" then
            local suffix = (not t.done and claimed) and (" (claimed: " .. claimed .. ")") or ""
            out[#out + 1] = string.format("[%s] [%s] %s%s", handles[t], t.done and "x" or " ", t.summary, suffix)
        elseif not t.done then
            local suffix = claimed and (" (claimed: " .. claimed .. ")") or ""
            out[#out + 1] = string.format("[%s] %s%s", handles[t], t.summary, suffix)
        end
    end
    return out
end

-- ── tm done ───────────────────────────────────────────────────────────────

local FIELD = "^    > %*%*[A-Za-z][A-Za-z0-9_%-]*:%*%*"

-- Stamp or replace a labeled field in a task's payload (§4.4.2).
-- An existing field is replaced in place; a new one joins the leading
-- run of labeled fields, inserting a blank line before freeform content
-- directly beneath the task line (V11).
local function stamp_field(lines, task, key, value)
    local stamp = "    > **" .. key .. ":** " .. value
    local existing_start, existing_end = tmid.field(lines, task, key)
    if existing_start then
        for k = existing_end, existing_start + 1, -1 do table.remove(lines, k) end
        lines[existing_start] = stamp
        return
    end
    local last = block_end(lines, task)
    local at = task.line + 1
    while at <= last and (lines[at]:match(FIELD) or
            (at > task.line + 1 and lines[at]:match("^    > ") and lines[at - 1]:match("^    > "))) do
        at = at + 1
    end
    table.insert(lines, at, stamp)
    local after = lines[at + 1]
    if at == task.line + 1 and after and at + 1 <= last + 1 and after:match("^    ")
        and not after:match("^    > ") then
        table.insert(lines, at + 1, "")
    end
end

-- Remove a named labeled field and its continuation lines from a task's
-- payload. Also removes a blank line left directly beneath the task line
-- before remaining payload content. Returns true if removed, false if absent.
-- Remove every labeled field named `key` and its continuation lines from a
-- task's payload. Also removes a blank line left directly beneath the task
-- line before remaining payload content. Returns true if any were removed.
local function remove_field(lines, task, key)
    local matches = tmid.fields(lines, task, key)
    if #matches == 0 then return false end
    local total_removed = 0
    for idx = #matches, 1, -1 do
        local start_line, end_line = matches[idx].start_line, matches[idx].end_line
        local removed = end_line - start_line + 1
        for k = end_line, start_line, -1 do table.remove(lines, k) end
        if start_line == task.line + 1 and lines[start_line] == ""
            and lines[start_line + 1] and lines[start_line + 1]:match("^    ") then
            table.remove(lines, start_line)
            removed = removed + 1
        end
        total_removed = total_removed + removed
    end
    if task.payload_end then
        task.payload_end = task.payload_end - total_removed
        if task.payload_end < task.payload_start then
            task.payload_start, task.payload_end = nil, nil
        end
    end
    return true
end

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

        remove_field(lines, task, "Claimed")
        local value = opts.date or os.date("%Y-%m-%d")
        if opts.git_sha then value = value .. " git:" .. opts.git_sha end
        stamp_field(lines, task, "Completed", value)

        local ok, werr = write_lines(file, lines, nl)
        if not ok then return false, werr end
        return true, task, handles
    end)
end

-- ── tm claim and tm release ──────────────────────────────────────────────

-- Resolve and validate the claimant: --as NAME, else $TM_CLAIMANT, else
-- the current branch of the working directory, else nil (date alone).
local function resolve_claimant(as_opt)
    local name = as_opt
    if name == nil then
        local env = os.getenv("TM_CLAIMANT")
        if env and env ~= "" then name = env end
    end
    if name == nil then
        name = tmgit.branch(".")
    end
    if not name or name == "" then return "" end
    if name:match("[\r\n]") then return nil, "claimant cannot contain a newline" end
    if name:match("%*%*[A-Za-z][A-Za-z0-9_%-]*:%*%*") then
        return nil, "claimant cannot contain a labeled-field marker (**Key:**)"
    end
    return name
end

-- Stamp a Claimed field on a pending task under the lock. opts: file |
-- tasks_dir, query, as, force, date (default: today, local time).
function M.claim(opts)
    local claimant, cerr = resolve_claimant(opts.as)
    if not claimant then return false, cerr end

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

        local existing_start, _, existing_val = tmid.field(lines, task, "Claimed")
        if existing_start and not opts.force then
            return false, "already_claimed", { task = task, handles = handles, value = existing_val }
        end

        local value = (opts.date or os.date("%Y-%m-%d")) .. (claimant ~= "" and (" " .. claimant) or "")
        stamp_field(lines, task, "Claimed", value)

        local ok, werr = write_lines(file, lines, nl)
        if not ok then return false, werr end
        return true, task, handles
    end)
end

-- Remove a Claimed field from a pending task under the lock. opts: file |
-- tasks_dir, query.
function M.release(opts)
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

        if not remove_field(lines, task, "Claimed") then
            return false, "not_claimed", { task = task, handles = handles }
        end

        local ok, werr = write_lines(file, lines, nl)
        if not ok then return false, werr end
        return true, task, handles
    end)
end

-- ── tm move ───────────────────────────────────────────────────────────────

-- The tasks of the document at `path`, or nil when it cannot be read.
local function tasks_of(path, warned)
    local lines = read_file(path, warned)
    return lines and tmscan.tasks(lines)
end

-- The document a move with no --from takes its task from: future.tm.md,
-- unless the task is not there but is in active.tm.md. Returns the path
-- and the paths that were searched.
local function infer_source(cfg, query, warned)
    local function matches(path)
        local tasks = tasks_of(path, warned)
        if not tasks then return false end
        local task, reason = M.find_task(tasks, query)
        return task ~= nil or reason ~= "not_found"
    end
    local searched = { cfg.future_path, cfg.active_path }
    if not matches(cfg.future_path) and matches(cfg.active_path) then
        return cfg.active_path, searched
    end
    return cfg.future_path, searched
end

-- The document a move with no --to puts the task in: the one holding the
-- --before/--after anchor when exactly one of active.tm.md and
-- future.tm.md does, else active.tm.md.
local function infer_destination(cfg, anchor, warned)
    if not anchor then return cfg.active_path end
    local holders = {}
    for _, path in ipairs({ cfg.active_path, cfg.future_path }) do
        local tasks = tasks_of(path, warned)
        if tasks and (M.find_task(tasks, anchor)) then holders[#holders + 1] = path end
    end
    return #holders == 1 and holders[1] or cfg.active_path
end

-- Move a task (with its payload) from one document to another, or to
-- another section of the same document, or directly before or after a
-- named task (opts.before / opts.after). The destination is written first,
-- so an interrupted move leaves a duplicate rather than losing the task.
-- Without opts.from the task is taken from future.tm.md, else active.tm.md;
-- without opts.to it goes to the document holding the anchor, else
-- active.tm.md. Returns true, task, handles, {from=, to=, same=}.
function M.move(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local anchor = opts.before or opts.after
    local warned = {}
    local from, searched = opts.from, { opts.from }
    if not from then from, searched = infer_source(cfg, opts.query, warned) end
    local to = opts.to or infer_destination(cfg, anchor, warned)

    return with_locks({ dir_of(from), dir_of(to) }, function()
        local src, src_nl = read_file(from, warned)
        if not src then return false, "no such file: " .. from end
        local dest, dest_nl = read_file(to, warned)
        if not dest then return false, "no such file: " .. to end
        local same = same_file(from, to)

        local tasks = tmscan.tasks(src)
        local handles = M.handles(tasks)
        local task, err, candidates = M.find_task(tasks, opts.query)
        if not task then
            return false, err, { candidates = candidates, handles = handles,
                searched = searched, inferred = not opts.from }
        end

        if same and not (opts.from or opts.to or anchor or opts.section) then
            return false, "task is already in " .. to .. "; give --to, --section, --before or --after"
        end
        if same and anchor and M.find_task(tasks, anchor) == task then
            return false, "cannot place a task relative to itself"
        end

        local last = block_end(src, task)
        local block, rest = {}, {}
        for i = 1, #src do
            if i >= task.line and i <= last then block[#block + 1] = src[i]
            else rest[#rest + 1] = src[i] end
        end

        if same then
            local at, aerr, adetail = placement(rest, opts)
            if not at then return false, adetail and aerr or (aerr .. " in " .. to), adetail end
            local ok, werr = write_lines(to, splice(rest, at, block), dest_nl)
            if not ok then return false, werr end
            return true, task, handles, { from = from, to = to, same = true }
        end

        local at, aerr, adetail = placement(dest, opts)
        if not at then return false, adetail and aerr or (aerr .. " in " .. to), adetail end
        local ok, werr = write_lines(to, splice(dest, at, block), dest_nl)
        if not ok then return false, werr end
        ok, werr = write_lines(from, rest, src_nl)
        if not ok then return false, werr end
        return true, task, handles, { from = from, to = to, same = false }
    end)
end

-- ── tm add ────────────────────────────────────────────────────────────────

-- `paths` plus `extra` when it is not already among them.
local function with_file(paths, extra)
    for _, p in ipairs(paths) do
        if p == extra then return paths end
    end
    paths[#paths + 1] = extra
    return paths
end

-- Add a pending task to an existing document, stamped with an identifier
-- unused in any task file unless its text already carries one. opts: text,
-- priority, section | before | after, file | tasks_dir, generate (identifier source, for
-- tests). Returns true, task-ish; or false, reason.
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

    return tmio.with_lock(dir_of(file), function()
        local lines, nl = read_file(file)
        if not lines then return false, "no such file: " .. file end
        local at, aerr, adetail = placement(lines, opts)
        if not at then return false, adetail and aerr or (aerr .. " in " .. file), adetail end
        local texts = tmid.read_texts(with_file(tmid.task_files(cfg), file))
        local supplied = tmid.of(text)
        if supplied then
            if tmid.taken(supplied, texts) then
                return false, tmid.PREFIX .. supplied .. " is already in use in the task files"
            end
        else
            local id, ierr = tmid.fresh(texts, opts.generate)
            if not id then return false, ierr end
            text = text .. " " .. tmid.PREFIX .. id
        end
        local task_line = "- [ ] " .. text
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

-- ── tm id ─────────────────────────────────────────────────────────────────

-- Stamp an identifier on every pending task that lacks one. Completed
-- tasks are never touched: their text is a record. opts: files (default:
-- the active and future files) | tasks_dir, generate.
-- Returns true, stamped { file, id, summary }, duplicates (tmid.duplicates
-- over every task file); or false, reason.
function M.stamp(opts)
    opts = opts or {}
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local files = opts.files
    if not files then
        files = {}
        for _, path in ipairs({ cfg.active_path, cfg.future_path }) do
            if tmio.file_exists(path) then files[#files + 1] = path end
        end
    end
    local dirs = {}
    for _, f in ipairs(files) do dirs[#dirs + 1] = dir_of(f) end

    return with_locks(dirs, function()
        local all = tmid.task_files(cfg)
        for _, f in ipairs(files) do with_file(all, f) end
        local texts = tmid.read_texts(all)

        -- Draw every identifier before writing anything, so a failed draw
        -- leaves all files as they were.
        local stamped, rewrites = {}, {}
        for _, file in ipairs(files) do
            local lines, nl = read_file(file)
            if not lines then return false, "no such file: " .. file end
            local changed = false
            for _, t in ipairs(tmscan.tasks(lines)) do
                if not t.done and not tmid.of(t.summary) then
                    local id, err = tmid.fresh(texts, opts.generate)
                    if not id then return false, err end
                    texts[#texts + 1] = tmid.PREFIX .. id
                    lines[t.line] = lines[t.line]:gsub("%s+$", "") .. " " .. tmid.PREFIX .. id
                    stamped[#stamped + 1] = { file = file, id = id, summary = tmscan.task_summary(lines[t.line]) }
                    changed = true
                end
            end
            if changed then rewrites[#rewrites + 1] = { file = file, lines = lines, nl = nl } end
        end
        for _, r in ipairs(rewrites) do
            local ok, werr = write_lines(r.file, r.lines, r.nl)
            if not ok then return false, werr end
        end
        return true, stamped, tmid.duplicates(all)
    end)
end

-- ── tm payload ────────────────────────────────────────────────────────────

-- A task's payload lines without the four-space payload indent.
local function payload_of(lines, task)
    local out = {}
    for i = task.line + 1, block_end(lines, task) do
        out[#out + 1] = lines[i]:match("^%s*$") and "" or lines[i]:sub(5)
    end
    return out
end

-- `text` (payload content, unindented) as payload lines, without leading
-- and trailing blank lines; also the number of leading lines dropped.
local function payload_lines(text)
    local raw = tmscan.lines_of(text)
    local first, last = 1, #raw
    while first <= last and raw[first]:match("^%s*$") do first = first + 1 end
    while last >= first and raw[last]:match("^%s*$") do last = last - 1 end
    local out = {}
    for i = first, last do
        out[#out + 1] = raw[i] == "" and "" or ("    " .. raw[i])
    end
    return out, first - 1
end

-- Print, append to, or replace a task's payload. opts: query, file |
-- tasks_dir, mode ("append" | "replace"; nil reads), text (the new payload
-- content, unindented, as `tm dedent` emits it). Without opts.file the task
-- is looked for in active.tm.md, then future.tm.md. The task with its new
-- payload must pass validation, so a write can never break the document.
-- Returns true, task, handles, payload (the task's unindented payload
-- lines when reading); or false, reason, detail.
function M.payload(opts)
    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local files = opts.file and { opts.file } or { cfg.active_path, cfg.future_path }

    local function run()
        local file, lines, nl, task, handles, failure
        local readable = false
        for _, path in ipairs(files) do
            local path_lines, path_nl = read_file(path)
            if path_lines then
                readable = true
                local tasks = tmscan.tasks(path_lines)
                local found, err, candidates = M.find_task(tasks, opts.query)
                if found or err ~= "not_found" then
                    file, lines, nl, task, handles = path, path_lines, path_nl, found, M.handles(tasks)
                    if not found then failure = { err, { candidates = candidates, handles = handles } } end
                    break
                end
            end
        end
        if not readable then return false, "no such file: " .. files[1] end
        if failure then return false, failure[1], failure[2] end
        if not task then return false, "not_found", { searched = files } end
        if not opts.mode then return true, task, handles, payload_of(lines, task) end

        local new, dropped = payload_lines(opts.text or "")
        if #new == 0 then return false, "the new payload on standard input is empty; nothing written" end

        local last = block_end(lines, task)
        local block = { lines[task.line] }
        if opts.mode == "append" and last > task.line then
            for i = task.line + 1, last do block[#block + 1] = lines[i] end
            block[#block + 1] = ""
        end
        local kept = #block
        local errors_before = #tmval.validate_lines(block)
        for _, l in ipairs(new) do block[#block + 1] = l end
        local errors = tmval.validate_lines(block)
        if #errors > errors_before then
            local msgs = {}
            for _, e in ipairs(errors) do
                local where = e.line > kept and ("stdin:" .. (e.line - kept + dropped))
                    or (file .. ":" .. (task.line + e.line - 1))
                msgs[#msgs + 1] = string.format("  %s: [%s] %s", where, e.rule, e.msg)
            end
            return false, "the payload would not be valid; nothing written:\n" .. table.concat(msgs, "\n")
        end

        local out = {}
        for i = 1, task.line - 1 do out[#out + 1] = lines[i] end
        for _, l in ipairs(block) do out[#out + 1] = l end
        for i = last + 1, #lines do out[#out + 1] = lines[i] end
        local ok, werr = write_lines(file, out, nl)
        if not ok then return false, werr end
        return true, task, handles
    end

    if not opts.mode then return run() end
    local dirs = {}
    for _, path in ipairs(files) do dirs[#dirs + 1] = dir_of(path) end
    return with_locks(dirs, run)
end

-- ── tm next ───────────────────────────────────────────────────────────────

local function select_next(lines, file, cfg, opts)
    local tasks = tmscan.tasks(lines)
    local handles = M.handles(tasks)
    local all = with_file(tmid.task_files(cfg), file)
    local status, warnings = {}, {}
    local best
    local claimed_skipped = 0
    for _, t in ipairs(tasks) do
        if not t.done and has_tags(t.summary, opts.tags, opts.not_tags) then
            if tmid.field(lines, t, "Claimed") then
                claimed_skipped = claimed_skipped + 1
            else
                local ready = true
                for _, dep in ipairs(tmid.depends(lines, t)) do
                    if status[dep] == nil then status[dep] = tmid.status(dep, all) or "unknown" end
                    if status[dep] == "unknown" then
                        warnings[#warnings + 1] = string.format("[%s] depends on %s%s, which names no task",
                            handles[t], tmid.PREFIX, dep)
                    end
                    if status[dep] ~= "done" then ready = false end
                end
                -- "~" sorts after every priority letter; strict < keeps file order.
                if ready and (not best or (t.priority or "~") < (best.priority or "~")) then best = t end
            end
        end
    end
    return best, handles, warnings, claimed_skipped
end

-- The task to start (§5.1): among the unclaimed pending tasks of the active
-- file that match the tag filters and have no unmet dependency, the one with
-- the highest priority flag, or the first in file order when none is
-- flagged. A dependency is met only when the task it names is completed,
-- in any task file. opts: file | tasks_dir, tags, not_tags, claim, as, date.
-- Returns task (nil when none is ready), handles, warnings, err, claimed_skipped.
function M.next(opts)
    opts = opts or {}
    local claimant
    if opts.claim then
        local cerr
        claimant, cerr = resolve_claimant(opts.as)
        if not claimant then return nil, nil, nil, cerr end
    end

    local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
    local file = opts.file or cfg.active_path

    if not opts.claim then
        local lines = read_file(file)
        if not lines then return nil, nil, nil, "no such file: " .. file end
        local best, handles, warnings, claimed_skipped = select_next(lines, file, cfg, opts)
        return best, handles, warnings, nil, claimed_skipped
    end

    return tmio.with_lock(dir_of(file), function()
        local lines, nl = read_file(file)
        if not lines then return nil, nil, nil, "no such file: " .. file end
        local best, handles, warnings, claimed_skipped = select_next(lines, file, cfg, opts)
        if best then
            local value = (opts.date or os.date("%Y-%m-%d")) .. (claimant ~= "" and (" " .. claimant) or "")
            stamp_field(lines, best, "Claimed", value)
            local ok, werr = write_lines(file, lines, nl)
            if not ok then return nil, nil, nil, werr end
        end
        return best, handles, warnings, nil, claimed_skipped
    end)
end

-- ── CLI ───────────────────────────────────────────────────────────────────

local USAGE = {
    list = "Usage: tm list [--pending|--all] [--claimed|--unclaimed] [--not TAG]... [TAG...] [--tasks-dir DIR] [file...]   (TAG: +project or @context)",
    next = "Usage: tm next [--claim [--as NAME]] [--not TAG]... [TAG...] [--file FILE] [--tasks-dir DIR]   (TAG: +project or @context)",
    id   = "Usage: tm id [--tasks-dir DIR] [file...]",
    done = "Usage: tm done [options] [--] <handle-or-pattern>   (options: --git [REV], --file FILE, --tasks-dir DIR)",
    claim = "Usage: tm claim [options] [--] <handle-or-pattern>   (options: --as NAME, --force, --file FILE, --tasks-dir DIR)",
    release = "Usage: tm release [options] [--] <handle-or-pattern>   (options: --file FILE, --tasks-dir DIR)",
    move = "Usage: tm move [options] [--] <handle-or-pattern>   (options: --from FILE, --to FILE, --section SECTION | --before TASK | --after TASK, --tasks-dir DIR)",
    payload = "Usage: tm payload [options] [--] <handle-or-pattern>   (options: --append | --replace, --file FILE, --tasks-dir DIR)\n" ..
           "  Prints the task's payload without its four-space indent. --append adds standard input beneath it,\n" ..
           "  --replace puts standard input in its place; the input is unindented payload content.",
    add  = "Usage: tm add [options] [--] <task-text>   (options: -p|--priority PRI, --section SECTION | --before TASK | --after TASK, --file FILE, --tasks-dir DIR)\n" ..
           "  A new identifier is stamped unless <task-text> already carries one (e.g. id:z0114), which must be unused.",
}

local VALUE_OPTS = {
    ["--tasks-dir"] = "tasks_dir", ["--file"] = "file", ["--section"] = "section",
    ["-p"] = "priority", ["--priority"] = "priority", ["--from"] = "from", ["--to"] = "to",
    ["--before"] = "before", ["--after"] = "after", ["--as"] = "as",
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
    query = detail.query or query
    if reason == "ambiguous_hash" or reason == "ambiguous_pattern" then
        tmio.die(string.format("Ambiguous %s '%s' matches %d tasks:\n%s\n%s",
            reason == "ambiguous_hash" and "handle" or "pattern", query, #detail.candidates,
            M.format_candidates(detail.candidates, detail.handles),
            "Use one of the handles shown, or a more specific pattern."))
    elseif reason == "already_completed" then
        tmio.die(string.format("Task is already completed: [%s] %s",
            handle_of(detail.task, detail.handles), detail.task.summary))
    elseif reason == "already_claimed" then
        tmio.die(string.format("Task is already claimed (%s): [%s] %s",
            detail.value or "", handle_of(detail.task, detail.handles), detail.task.summary))
    elseif reason == "not_claimed" then
        tmio.die(string.format("Task is not claimed: [%s] %s",
            handle_of(detail.task, detail.handles), detail.task.summary))
    elseif reason == "not_found" then
        if detail.searched then
            tmio.die(string.format("No task found matching '%s' in %s.%s", query,
                table.concat(detail.searched, ", "), detail.inferred and " Use --from FILE to search elsewhere." or ""))
        end
        tmio.die(string.format("No task found matching '%s'.", query))
    end
    tmio.die(tostring(reason))
end

function M.run(subcmd, args)
    args = args or {}
    local opts, positionals = {}, {}
    local filter = "pending"
    local not_tags = {}
    local git_flag, git_rev, git_at = false, nil, nil

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "--" then
            -- End of options: everything after is task text or a pattern,
            -- even when it starts with '-'.
            for j = i + 1, #args do positionals[#positionals + 1] = args[j] end
            break
        elseif a == "--not" then
            if not args[i + 1] then tmio.die(a .. " requires an argument") end
            not_tags[#not_tags + 1] = args[i + 1]
            i = i + 1
        elseif VALUE_OPTS[a] then
            if not args[i + 1] then tmio.die(a .. " requires an argument") end
            opts[VALUE_OPTS[a]] = args[i + 1]
            i = i + 1
        elseif a == "--pending" then
            filter = "pending"
        elseif a == "--all" then
            filter = "all"
        elseif a == "--claimed" or a == "--unclaimed" then
            if subcmd ~= "list" then tmio.die(a .. " applies only to tm list\n" .. USAGE[subcmd]) end
            if opts.claim_filter then tmio.die("give --claimed or --unclaimed, not both\n" .. USAGE.list) end
            opts.claim_filter = a:sub(3)
        elseif a == "--append" or a == "--replace" then
            if subcmd ~= "payload" then tmio.die(a .. " applies only to tm payload\n" .. USAGE[subcmd]) end
            if opts.mode then tmio.die("give --append or --replace, not both\n" .. USAGE.payload) end
            opts.mode = a:sub(3)
        elseif a == "--force" then
            if subcmd ~= "claim" then tmio.die("--force applies only to tm claim\n" .. USAGE[subcmd]) end
            opts.force = true
        elseif a == "--claim" then
            if subcmd ~= "next" then tmio.die("--claim applies only to tm next\n" .. USAGE[subcmd]) end
            opts.claim = true
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
    if opts.as ~= nil and subcmd ~= "claim" and subcmd ~= "next" then
        tmio.die("--as applies only to tm claim and tm next\n" .. USAGE[subcmd])
    end
    if opts.as ~= nil and subcmd == "next" and not opts.claim then
        tmio.die("--as requires --claim with tm next\n" .. USAGE.next)
    end

    -- For list and next, a positional starting with '+' or '@' is a tag
    -- filter; anything else names a file (`./@name` for a file so named).
    local tags = {}
    if subcmd == "list" or subcmd == "next" then
        local others = {}
        for _, p in ipairs(positionals) do
            if p:match("^[+@]") then tags[#tags + 1] = p else others[#others + 1] = p end
        end
        positionals = others
    elseif #not_tags > 0 then
        tmio.die("--not applies only to tm list and tm next\n" .. USAGE[subcmd])
    end

    if subcmd == "next" then
        if #positionals > 0 then
            tmio.die("Unexpected argument: " .. positionals[1] .. " (a tag starts with + or @)\n" .. USAGE.next)
        end
        local task, handles, warnings, err, claimed_skipped = M.next({
            file = opts.file, tasks_dir = opts.tasks_dir, tags = tags, not_tags = not_tags,
            claim = opts.claim, as = opts.as,
        })
        if err then tmio.die(err) end
        for _, w in ipairs(warnings) do io.stderr:write("tm: " .. w .. "\n") end
        if task then
            print(string.format("[%s] %s", handles[task], task.summary))
        elseif claimed_skipped and claimed_skipped > 0 then
            io.stderr:write(string.format("tm: no task is ready (%d claimed; see tm list)\n", claimed_skipped))
        else
            io.stderr:write("tm: no task is ready\n")
        end
        os.exit(0)
    end

    if subcmd == "id" then
        local ok, stamped, duplicates = M.stamp({
            tasks_dir = opts.tasks_dir, files = #positionals > 0 and positionals or nil,
        })
        if not ok then tmio.die("Failed to stamp identifiers: " .. tostring(stamped)) end
        for _, s in ipairs(stamped) do
            print(string.format("Stamped: [%s] %s", s.id, s.summary))
        end
        if #stamped == 0 then print("Nothing to stamp: every pending task has an identifier.") end
        for _, d in ipairs(duplicates) do
            io.stderr:write("tm: " .. tmid.describe_duplicate(d) .. "\n")
        end
        os.exit(0)
    end

    if subcmd == "list" then
        local cfg = tmconfig.resolve({ tasks_dir = opts.tasks_dir })
        local files = #positionals > 0 and positionals or { cfg.active_path }
        local warned = #files > 1 and {} or nil
        for idx, f in ipairs(files) do
            local items, err = M.format_list(f, {
                filter = filter, claim_filter = opts.claim_filter,
                tags = tags, not_tags = not_tags, warned = warned,
            })
            if not items then tmio.die(err) end
            if #files > 1 then
                if idx > 1 then print("") end
                print("== " .. f)
            end
            for _, item in ipairs(items) do print(item) end
            if #items == 0 then
                -- On stderr, so a script reading stdout still sees an
                -- empty listing.
                io.stderr:write(string.format("tm: no %stasks in %s\n",
                    filter == "all" and "" or "pending ", f))
            end
        end
        os.exit(0)
    end

    if subcmd == "add" then
        if #positionals == 0 then tmio.die("tm add requires task text.\n" .. USAGE.add) end
        local ok, res, handles = M.add({
            text = table.concat(positionals, " "), priority = opts.priority,
            section = opts.section, file = opts.file, tasks_dir = opts.tasks_dir,
            before = opts.before, after = opts.after,
        })
        if not ok then
            if handles and handles.query then report_failure(nil, res, handles) end
            tmio.die("Failed to add task: " .. tostring(res))
        end
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

    if subcmd == "claim" then
        local ok, res, detail = M.claim({
            file = opts.file, tasks_dir = opts.tasks_dir, query = query, as = opts.as, force = opts.force,
        })
        if not ok then report_failure(query, res, detail) end
        print(string.format("Claimed: [%s] %s", handle_of(res, detail), res.summary))
        os.exit(0)
    end

    if subcmd == "release" then
        local ok, res, detail = M.release({
            file = opts.file, tasks_dir = opts.tasks_dir, query = query,
        })
        if not ok then report_failure(query, res, detail) end
        print(string.format("Released: [%s] %s", handle_of(res, detail), res.summary))
        os.exit(0)
    end

    if subcmd == "payload" then
        local ok, res, detail, payload = M.payload({
            query = query, file = opts.file, tasks_dir = opts.tasks_dir, mode = opts.mode,
            text = opts.mode and io.read("*a") or nil,
        })
        if not ok then report_failure(query, res, detail) end
        if opts.mode then
            print(string.format("%s: [%s] %s", opts.mode == "append" and "Appended" or "Replaced",
                handle_of(res, detail), res.summary))
        elseif #payload > 0 then
            io.write(table.concat(payload, "\n"), "\n")
        end
        os.exit(0)
    end

    if subcmd == "move" then
        local ok, res, detail, info = M.move({
            query = query, from = opts.from or opts.file, to = opts.to,
            section = opts.section, tasks_dir = opts.tasks_dir,
            before = opts.before, after = opts.after,
        })
        if not ok then report_failure(query, res, detail) end
        local from_note = info and not info.same and (" (from " .. info.from:match("[^/]*$") .. ")") or ""
        print(string.format("Moved: [%s] %s%s", handle_of(res, detail), res.summary, from_note))
        os.exit(0)
    end
end

return M
