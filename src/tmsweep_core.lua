-- tmsweep_core.lua — Pure parsing/decision/mutation logic used by tmsweep
-- (SPEC-TASKMARK-04 §5.3-§5.5): task-level sweep, blank-line normalization,
-- and archive aging. Kept require-able so tests can exercise each function
-- directly.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path
local tmscan = require("tmscan")

local M = {}

-- Every task-owning section in `lines`, in document order: the outermost
-- headings that directly own at least one task, skipping any that sit
-- inside a section already selected. Used only by archive aging (§5.5),
-- which groups completed.tm.md by its "## Sprint ..." sections regardless
-- of how deeply they're nested under a top H1.
--
-- One forward pass over the headings (no parsed tree): a heading's own
-- span always runs to the very next heading, of any level, so "does this
-- heading directly own a task" never needs a child link to answer. Only
-- the recursion in the old tree-walk -- "skip a heading's whole subtree
-- once an ancestor is already a boundary" -- needs any memory across
-- headings, and a level-keyed stack of one boolean carries exactly that.
function M.boundary_sections(lines)
    local headers = {}
    do
        local open
        for i, kind, fields in tmscan.iter(lines) do
            if kind == "heading" then
                if open then open.body_end = i end
                open = { level = fields.level, title = fields.text, header_line = i, body_start = i + 1 }
                headers[#headers + 1] = open
            end
        end
        if open then open.body_end = #lines + 1 end
    end

    local all_tasks = tmscan.tasks(lines)
    local function has_direct_task(h)
        for _, t in ipairs(all_tasks) do
            if t.line >= h.body_start and t.line <= h.body_end - 1 then return true end
        end
        return false
    end

    local result, stack = {}, {}
    for _, h in ipairs(headers) do
        while #stack > 0 and stack[#stack].level >= h.level do
            table.remove(stack)
        end
        local blocked = #stack > 0 and stack[#stack].blocked
        if not blocked and has_direct_task(h) then
            result[#result + 1] = h
            blocked = true
        end
        table.insert(stack, { level = h.level, blocked = blocked })
    end
    return result
end

-- The latest per-task `> **Completed:** YYYY-MM-DD ...` date found anywhere
-- in a section's block lines (as a UTC-midnight epoch), or nil if none.
function M.section_completed_date(block_lines)
    if not block_lines or #block_lines == 0 then return nil end
    local latest = nil
    for _, line in ipairs(block_lines) do
        local date = line:match("^    > %*%*Completed:%*%* (%d%d%d%d%-%d%d%-%d%d)")
        if date then
            local epoch = tmscan.parse_iso8601(date)
            if epoch and (not latest or epoch > latest) then
                latest = epoch
            end
        end
    end
    return latest
end

-- Remove the full line ranges of the given nodes from lines. Surgical
-- mutation: untouched content and code blocks are preserved byte-for-byte.
-- A doubled blank line can be left at the removal seam; cap_completed's
-- only caller always runs the result through normalize_blank_lines, so
-- collapsing it here would just be redundant work.
function M.remove_sections(lines, nodes)
    local removed = {}
    local moved_blocks = {}
    for _, node in ipairs(nodes) do
        local block_lines = {}
        for i = node.header_line, node.body_end - 1 do
            table.insert(block_lines, lines[i])
            removed[i] = true
        end
        table.insert(moved_blocks, { title = node.title, lines = block_lines })
    end

    local kept = {}
    for i = 1, #lines do
        if not removed[i] then
            table.insert(kept, lines[i])
        end
    end

    return kept, moved_blocks
end

-- Insert `block` (an array of lines) into `lines` at position `at` (before
-- the current lines[at]), unconditionally separating it from what's on
-- either side with a blank line (unless at a file boundary). This can
-- leave a doubled blank line at a seam that already had one; callers run
-- the result through normalize_blank_lines, which is exactly the tool for
-- collapsing that and costs nothing since it is idempotent on lines that
-- were already clean. Lines interior to `block` are never touched.
local function splice_with_seams(lines, at, block)
    local result = {}
    for i = 1, at - 1 do
        result[#result + 1] = lines[i]
    end
    if #result > 0 then
        result[#result + 1] = ""
    end
    for _, l in ipairs(block) do
        result[#result + 1] = l
    end
    if at <= #lines then
        result[#result + 1] = ""
    end
    for i = at, #lines do
        result[#result + 1] = lines[i]
    end
    return result
end

-- ── Task-level sweep (§5.3) ─────────────────────────────────────────────

-- Move every `- [x]` task and its payload out of active_lines. Returns the
-- replacement active lines and the moved blocks (array of {lines=...}, in
-- document order), or nil, nil when there is nothing to sweep. Headings and
-- top-level prose are never swept.
function M.sweep(active_lines)
    local tasks = tmscan.tasks(active_lines)
    local removed = {}
    local moved = {}
    for _, t in ipairs(tasks) do
        if t.done then
            local last = t.payload_end or t.line
            local block_lines = {}
            for i = t.line, last do
                block_lines[#block_lines + 1] = active_lines[i]
                removed[i] = true
            end
            moved[#moved + 1] = { lines = block_lines }
        end
    end

    if #moved == 0 then return nil, nil end

    local kept = {}
    for i = 1, #active_lines do
        if not removed[i] then
            kept[#kept + 1] = active_lines[i]
        end
    end

    return kept, moved
end

-- The document title: the first heading, when it is level 1. nil when the
-- first heading is a section heading or there are no headings at all.
local function title_line(lines)
    for i = 1, #lines do
        local kind, fields = tmscan.classify(lines[i])
        if kind == "heading" then
            return fields.level == 1 and i or nil
        end
    end
    return nil
end

-- The first heading after line `after` (0 for the whole document), and its
-- classified fields.
local function next_heading(lines, after)
    for i = after + 1, #lines do
        local kind, fields = tmscan.classify(lines[i])
        if kind == "heading" then return i, fields end
    end
    return nil
end

-- Join chunks (arrays of lines) with one blank line between consecutive
-- chunks; no leading or trailing separator.
local function join_chunks(chunks)
    local block = {}
    for _, chunk in ipairs(chunks) do
        if #block > 0 then block[#block + 1] = "" end
        for _, l in ipairs(chunk) do block[#block + 1] = l end
    end
    return block
end

-- Insert moved task blocks into completed_lines, newest first (§6.3).
--
-- The document title is the first heading when it is level 1 (its text is
-- never matched). The *top section* is the first heading beneath the title,
-- or the first heading of all when there is no title. When `sprint_label`
-- names a heading ("## Sprint <label>", or "## <YYYY-MM>" as given) that is
-- already the top section, the blocks are prepended into it, directly
-- beneath its heading. Otherwise a new section is inserted at the top:
-- beneath the title, or above the first heading when there is no title, or
-- after any preamble prose when there are no headings at all. Content
-- inside each moved block is preserved verbatim; blank lines are normalized.
function M.insert_into_completed(completed_lines, moved_blocks, sprint_label)
    if not moved_blocks or #moved_blocks == 0 then return completed_lines end

    local sprint_heading
    if sprint_label and sprint_label ~= "" then
        if sprint_label:match("^Sprint") or sprint_label:match("^%d%d%d%d%-%d%d$") then
            sprint_heading = sprint_label
        else
            sprint_heading = "Sprint " .. sprint_label
        end
    end

    local title = title_line(completed_lines)
    local top, top_fields = next_heading(completed_lines, title or 0)

    local chunks = {}
    local insert_at
    if sprint_heading and top and top_fields.level == 2 and top_fields.text == sprint_heading then
        insert_at = top + 1
    else
        if title then
            insert_at = title + 1
        elseif top then
            insert_at = top
        else
            insert_at = #completed_lines + 1
        end
        if sprint_heading then chunks[#chunks + 1] = { "## " .. sprint_heading } end
    end
    for _, mb in ipairs(moved_blocks) do chunks[#chunks + 1] = mb.lines end

    return M.normalize_blank_lines(splice_with_seams(completed_lines, insert_at, join_chunks(chunks)))
end

-- Prepend `blocks` (array of {lines=...}, newest first) to an archive file
-- (§6.4): directly beneath its title, or at the top when it has none, so an
-- archive file reads newest first like completed.tm.md. Block content is
-- never altered; blank lines are normalized.
function M.prepend_blocks(lines, blocks)
    local chunks = {}
    for _, b in ipairs(blocks) do chunks[#chunks + 1] = b.lines end
    local title = title_line(lines)
    local insert_at = title and title + 1 or 1
    return M.normalize_blank_lines(splice_with_seams(lines, insert_at, join_chunks(chunks)))
end

-- ── Blank-line normalization (§5.3) ─────────────────────────────────────

-- Collapse any run of consecutive blank lines outside a fenced code block
-- to one, and drop trailing blank lines at end of file. Blank lines inside
-- a payload fence are content and are preserved byte for byte, using the
-- fence state tmscan already tracks.
function M.normalize_blank_lines(lines)
    local out = {}
    local prev_collapsed_blank = false
    for i, kind, _, _, _, fence_open in tmscan.iter(lines) do
        local raw = lines[i]
        if kind == "blank" and not fence_open then
            if not prev_collapsed_blank then
                out[#out + 1] = ""
            end
            prev_collapsed_blank = true
        else
            out[#out + 1] = raw
            prev_collapsed_blank = false
        end
    end

    while #out > 0 and out[#out] == "" do
        table.remove(out)
    end

    return out
end

-- ── Archive aging (§5.5) ─────────────────────────────────────────────────

-- Pure decision and extraction logic for aging sections out of
-- completed.tm.md: decides which of its sections are old enough to archive
-- (outside the `keep_min` newest and dated more than `keep_days` old by
-- their own most recent Completed stamp), and groups the aged-out sections
-- by the year/month of that same date, without touching any files.
function M.cap_completed(completed_lines, opts)
    if not completed_lines or not opts or not opts.now then
        return nil, nil
    end

    local now_epoch = tmscan.parse_iso8601(opts.now)
    if not now_epoch then
        return nil, nil
    end

    local keep_min = (opts.keep_min ~= nil) and opts.keep_min or 2
    local keep_days = (opts.keep_days ~= nil) and opts.keep_days or 14
    local cutoff_seconds = keep_days * 86400

    local nodes = M.boundary_sections(completed_lines)
    local stamped = {}

    for _, node in ipairs(nodes) do
        local block_lines = {}
        for i = node.header_line, node.body_end - 1 do
            table.insert(block_lines, completed_lines[i])
        end
        local ts_epoch = M.section_completed_date(block_lines)
        if ts_epoch then
            table.insert(stamped, { node = node, ts_epoch = ts_epoch })
        end
    end

    -- §5.5: a section's age and recency both derive from its own most
    -- recent Completed stamp, never from where it sits in the file, so the
    -- "newest keep_min" ranking has to sort on that stamp first.
    table.sort(stamped, function(a, b) return a.ts_epoch > b.ts_epoch end)

    local archived_nodes = {}
    local archived_epochs = {}

    for rank, entry in ipairs(stamped) do
        local age = now_epoch - entry.ts_epoch
        local keep = (rank <= keep_min) or (age < cutoff_seconds)
        if not keep then
            table.insert(archived_nodes, entry.node)
            table.insert(archived_epochs, entry.ts_epoch)
        end
    end

    if #archived_nodes == 0 then
        return nil, nil
    end

    local new_completed_lines, moved_blocks = M.remove_sections(completed_lines, archived_nodes)

    local archive_groups = {}
    local group_by_key = {}

    for idx, block in ipairs(moved_blocks) do
        local ts_epoch = archived_epochs[idx]
        local year = os.date("!%Y", ts_epoch)
        local month = os.date("!%m", ts_epoch)
        local key = year .. "-" .. month
        local group = group_by_key[key]
        if not group then
            group = { year = year, month = month, blocks = {} }
            group_by_key[key] = group
            table.insert(archive_groups, group)
        end
        table.insert(group.blocks, block)
    end

    return new_completed_lines, archive_groups
end

return M
