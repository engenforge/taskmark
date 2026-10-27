-- tmsweep_core.lua — Pure parsing/decision/mutation logic used by tmsweep
-- (SPEC-TASKMARK-03 §5.3-§5.5): task-level sweep, blank-line normalization,
-- and archive aging. Kept require-able so tests can exercise each function
-- directly.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path
local tmscan = require("tmscan")
local tmmeta = require("tmmeta")

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

-- Read the `project` frontmatter field value from lines. Returns nil if absent.
function M.frontmatter_project(lines)
    local tbl = tmmeta.split_frontmatter(lines)
    if not tbl then return nil end
    local v = tbl.project
    if type(v) == "string" then return v end
    return nil
end

-- Replace the `date:` field's value inside the leading frontmatter block.
-- Lines outside the frontmatter -- and the frontmatter itself when there is
-- no `date:` line to replace -- are left untouched.
function M.bump_frontmatter_date(lines, new_date)
    local out = tmmeta.set_date(lines, new_date)
    return out or lines
end

-- Replace the `sprint:` field's value the same way bump_frontmatter_date
-- replaces `date:`.
function M.bump_frontmatter_sprint(lines, new_sprint)
    local out = tmmeta.set_field(lines, "sprint", new_sprint)
    return out or lines
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

-- Insert moved task blocks into completed_lines, immediately after its
-- first heading line (located by position, never by matching heading
-- text). When `sprint_label` is given and a "## Sprint <sprint_label>"
-- heading is already the very next heading after that first one, the
-- blocks are appended into that existing section instead of creating a
-- duplicate. Surgical mutation: only collapses doubled blank lines at the
-- two splice seams; content inside each moved block is preserved verbatim.
function M.insert_into_completed(completed_lines, moved_blocks, sprint_label)
    if not moved_blocks or #moved_blocks == 0 then return completed_lines end

    local first_heading_line = nil
    for i = 1, #completed_lines do
        if tmscan.classify(completed_lines[i]) == "heading" then
            first_heading_line = i
            break
        end
    end

    local sprint_heading = sprint_label and sprint_label ~= "" and ("Sprint " .. sprint_label) or nil

    -- The section immediately following the first heading, if it already
    -- matches the current sprint.
    local existing_start, existing_end
    if first_heading_line and sprint_heading then
        for i = first_heading_line + 1, #completed_lines do
            local kind, fields = tmscan.classify(completed_lines[i])
            if kind == "heading" then
                if fields.level == 2 and fields.text == sprint_heading then
                    existing_start = i
                    existing_end = #completed_lines + 1
                    for j = i + 1, #completed_lines do
                        if tmscan.classify(completed_lines[j]) == "heading" then
                            existing_end = j
                            break
                        end
                    end
                end
                break -- only the very next heading counts as "the top section"
            end
        end
    end

    -- Blank lines only ever separate chunks *within* block; the outer
    -- leading/trailing separator is splice_with_seams' job, so the first
    -- chunk added here must not carry one of its own or that seam doubles.
    local block = {}
    local function add_chunk(chunk_lines)
        if #block > 0 then block[#block + 1] = "" end
        for _, l in ipairs(chunk_lines) do block[#block + 1] = l end
    end

    local insert_at

    if existing_start then
        insert_at = existing_end
        for _, mb in ipairs(moved_blocks) do add_chunk(mb.lines) end
    else
        if first_heading_line then
            insert_at = first_heading_line + 1
        else
            local fm, body_start = tmmeta.split_frontmatter(completed_lines)
            insert_at = fm and body_start or 1
        end
        if sprint_heading then add_chunk({ "## " .. sprint_heading }) end
        for _, mb in ipairs(moved_blocks) do add_chunk(mb.lines) end
    end

    return splice_with_seams(completed_lines, insert_at, block)
end

-- Append `blocks` (array of {lines=...}) to the end of `lines`, separated
-- from the existing content and from each other by exactly one blank line.
-- For archive files (§5.5): archive files are append-only and are never
-- rewritten, so this only ever touches the new tail -- nothing before the
-- seam is read as a tree, collapsed, or otherwise modified.
function M.append_blocks(lines, blocks)
    local result = {}
    for i = 1, #lines do result[#result + 1] = lines[i] end
    while #result > 0 and result[#result] == "" do
        table.remove(result)
    end
    for _, b in ipairs(blocks) do
        -- Only add a separator when the tail isn't already blank -- a
        -- block that itself ends with a blank line (its own trailing
        -- separator, carried over from where it was cut out) already
        -- serves as one. Block content itself is never inspected or
        -- altered, so fence interiors stay byte-for-byte.
        if #result > 0 and result[#result] ~= "" then result[#result + 1] = "" end
        for _, l in ipairs(b.lines) do result[#result + 1] = l end
    end
    return result
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

    local keep_min = (opts.keep_min ~= nil) and opts.keep_min or 10
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
