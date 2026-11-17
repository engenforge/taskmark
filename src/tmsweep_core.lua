-- tmsweep_core.lua — Pure parsing/decision/mutation logic used by tmsweep
-- (SPEC-TASKMARK-06 §5.3-§5.5): task-level sweep, blank-line normalization,
-- and archive aging. Kept require-able so tests can exercise each function
-- directly.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path
local tmscan = require("tmscan")

local M = {}

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

-- The first heading or task line in `lines`.
local function first_heading_or_task(lines)
    for i = 1, #lines do
        local kind = tmscan.classify(lines[i])
        if kind == "heading" or kind == "task" then return i end
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

-- Extract the Completed date from a task block's lines, or nil if none.
-- Matches only the 4-space payload labeled field outside fenced code blocks.
local function task_completed_date(block_lines)
    if not block_lines then return nil end
    for i, _, _, _, _, fence_open in tmscan.iter(block_lines) do
        if not fence_open then
            local date = block_lines[i]:match("^    > %*%*Completed:%*%* (%d%d%d%d%-%d%d%-%d%d)")
            if date then return date end
        end
    end
    return nil
end

-- Insert moved task blocks into completed_lines, newest first (§6.3).
--
-- The blocks of one sweep are ordered newest first by their own
-- `Completed` date; blocks with equal or no dates keep their document
-- order, dateless ones last. The document title is the first heading when
-- it is level 1 (its text is never matched). Tasks are inserted directly
-- beneath the title, or above the first heading/task when there is no
-- title, or after any preamble prose when there are no headings or tasks.
-- Content inside each moved block is preserved verbatim; blank lines are
-- normalized.
function M.insert_into_completed(completed_lines, moved_blocks)
    if not moved_blocks or #moved_blocks == 0 then return completed_lines end

    local sorted_blocks = {}
    for idx, mb in ipairs(moved_blocks) do
        sorted_blocks[#sorted_blocks + 1] = { mb = mb, date = task_completed_date(mb.lines) or "", idx = idx }
    end
    table.sort(sorted_blocks, function(a, b)
        if a.date ~= b.date then return a.date > b.date end
        return a.idx < b.idx
    end)

    local title = title_line(completed_lines)
    local insert_at
    if title then
        insert_at = title + 1
    else
        insert_at = first_heading_or_task(completed_lines) or (#completed_lines + 1)
    end

    local chunks = {}
    for _, item in ipairs(sorted_blocks) do
        chunks[#chunks + 1] = item.mb.lines
    end

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

-- Pure decision and extraction logic for aging individual tasks out of
-- completed.tm.md (§5.5):
--   1. Time-based: tasks outside the `keep_min` newest and dated at least
--      `keep_days` old by their own Completed stamp.
--   2. Size-based: when `max_bytes > 0` and completed.tm.md still exceeds
--      `max_bytes`, oldest dated tasks first until <= `max_bytes`, always
--      keeping at least 1 newest task.
-- Groups aged-out tasks by the year/month of their Completed date, newest
-- first, without touching any files.
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
    local max_bytes = tonumber(opts.max_bytes) or 0
    local nl = opts.nl or "\n"
    local cutoff_seconds = keep_days * 86400

    local function serialized_bytes(lines)
        if #lines == 0 then return 0 end
        return #(table.concat(lines, nl) .. nl)
    end

    local tasks = tmscan.tasks(completed_lines)
    local stamped = {}

    for _, t in ipairs(tasks) do
        local last = t.payload_end or t.line
        while last > t.line and completed_lines[last] == "" do
            last = last - 1
        end
        local block_lines = {}
        for i = t.line, last do
            block_lines[#block_lines + 1] = completed_lines[i]
        end
        local date_str = task_completed_date(block_lines)
        local ts_epoch = date_str and tmscan.parse_iso8601(date_str) or nil
        if ts_epoch then
            local _, fields = tmscan.classify(completed_lines[t.line])
            stamped[#stamped + 1] = {
                start_line = t.line,
                end_line = last,
                lines = block_lines,
                ts_epoch = ts_epoch,
                title = (fields and fields.description) or completed_lines[t.line],
            }
        end
    end

    if #stamped == 0 then
        local cur_bytes = serialized_bytes(completed_lines)
        if max_bytes > 0 and cur_bytes > max_bytes then
            return nil, nil, { over_cap = true, bytes = cur_bytes, max_bytes = max_bytes }
        end
        return nil, nil
    end

    -- §5.5: recency and age both derive from each task's own Completed stamp,
    -- breaking ties by document order.
    table.sort(stamped, function(a, b)
        if a.ts_epoch ~= b.ts_epoch then return a.ts_epoch > b.ts_epoch end
        return a.start_line < b.start_line
    end)

    local time_archived = {}
    for rank, entry in ipairs(stamped) do
        local age = now_epoch - entry.ts_epoch
        if (rank > keep_min) and (age >= cutoff_seconds) then
            time_archived[entry] = true
        end
    end

    -- Remaining dated candidates for size-based archival (oldest first,
    -- always preserving rank 1 so at least 1 newest task stays).
    local extra_candidates = {}
    for rank = #stamped, 2, -1 do
        local entry = stamped[rank]
        if not time_archived[entry] then
            extra_candidates[#extra_candidates + 1] = entry
        end
    end

    -- Precompute legacy level >= 2 heading spans once: each heading's full
    -- subtree runs until the next heading of equal or higher level (smaller
    -- level number), or EOF.
    local headings = {}
    for i, kind, fields in tmscan.iter(completed_lines) do
        if kind == "heading" then
            headings[#headings + 1] = { line = i, level = fields.level, subtree_end = #completed_lines }
        end
    end
    for idx, h in ipairs(headings) do
        for j = idx + 1, #headings do
            if headings[j].level <= h.level then
                h.subtree_end = headings[j].line - 1
                break
            end
        end
    end

    -- Precompute which tasks sit inside each level >= 2 heading's subtree.
    local legacy_headings = {}
    for _, h in ipairs(headings) do
        if h.level >= 2 then
            local sub_tasks = {}
            for _, t in ipairs(tasks) do
                if t.line > h.line and t.line <= h.subtree_end then
                    sub_tasks[#sub_tasks + 1] = t.line
                end
            end
            if #sub_tasks > 0 then
                legacy_headings[#legacy_headings + 1] = { line = h.line, task_lines = sub_tasks }
            end
        end
    end

    local function build_remaining(extra_k)
        local removed = {}
        for entry in pairs(time_archived) do
            for i = entry.start_line, entry.end_line do
                removed[i] = true
            end
        end
        for idx = 1, extra_k do
            local entry = extra_candidates[idx]
            for i = entry.start_line, entry.end_line do
                removed[i] = true
            end
        end

        for _, lh in ipairs(legacy_headings) do
            local has_kept = false
            for _, tline in ipairs(lh.task_lines) do
                if not removed[tline] then
                    has_kept = true
                    break
                end
            end
            if not has_kept then
                removed[lh.line] = true
            end
        end

        local kept = {}
        for i = 1, #completed_lines do
            if not removed[i] then
                kept[#kept + 1] = completed_lines[i]
            end
        end
        return M.normalize_blank_lines(kept)
    end

    local extra_k = 0
    local new_completed_lines = build_remaining(0)
    local cur_bytes = serialized_bytes(new_completed_lines)

    if max_bytes > 0 and cur_bytes > max_bytes and #extra_candidates > 0 then
        local lo, hi = 1, #extra_candidates
        local best_k = #extra_candidates
        local best_lines = nil
        local best_bytes = nil

        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local cand = build_remaining(mid)
            local b = serialized_bytes(cand)
            if b <= max_bytes then
                best_k = mid
                best_lines = cand
                best_bytes = b
                hi = mid - 1
            else
                lo = mid + 1
            end
        end

        extra_k = best_k
        if best_lines then
            new_completed_lines = best_lines
            cur_bytes = best_bytes
        else
            new_completed_lines = build_remaining(extra_k)
            cur_bytes = serialized_bytes(new_completed_lines)
        end
    end

    local archived_set = {}
    local archived_count = 0
    for entry in pairs(time_archived) do
        archived_set[entry] = true
        archived_count = archived_count + 1
    end
    for idx = 1, extra_k do
        archived_set[extra_candidates[idx]] = true
        archived_count = archived_count + 1
    end

    local info = {
        over_cap = (max_bytes > 0 and cur_bytes > max_bytes),
        bytes = cur_bytes,
        max_bytes = max_bytes,
    }

    if archived_count == 0 then
        return nil, nil, info
    end

    -- Collect archived tasks newest first so each archive file stays newest first.
    local archived_entries = {}
    for _, entry in ipairs(stamped) do
        if archived_set[entry] then
            archived_entries[#archived_entries + 1] = entry
        end
    end

    local archive_groups = {}
    local group_by_key = {}

    for _, entry in ipairs(archived_entries) do
        local year = os.date("!%Y", entry.ts_epoch)
        local month = os.date("!%m", entry.ts_epoch)
        local key = year .. "-" .. month
        local group = group_by_key[key]
        if not group then
            group = { year = year, month = month, blocks = {} }
            group_by_key[key] = group
            archive_groups[#archive_groups + 1] = group
        end
        group.blocks[#group.blocks + 1] = { title = entry.title, lines = entry.lines }
    end

    return new_completed_lines, archive_groups, info
end

return M
