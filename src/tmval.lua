#!/usr/bin/env lua
-- tm validate — SPEC-TASKMARK-04 §1.5 validator. Checks a document against
-- rules V3 through V14 and nothing else: no warning is fatal, and tag shape
-- or placement is never checked. One subcommand of the `tm` universal
-- taskmark utility; also runnable directly as `lua tmval.lua`.
-- Usage: tm validate [options] [file...]
-- If no file is given, defaults to the active file resolved via tmconfig.

local script_dir = arg and arg[0] and arg[0]:match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/?.lua;" .. script_dir .. "/../src/?.lua;" .. package.path
local tmconfig = require("tmconfig")
local tmscan   = require("tmscan")
local tmio     = require("tmio")

local function show_help()
    print([[
tm validate — SPEC-TASKMARK-04 taskmark validator

Usage:
  tm validate [options] [file...]
  tm validate                     Default: validate the active file resolved via
                                  tmconfig

Options:
  --fix                   Automatically repair common formatting errors
  -h, --help              Show this help message

Exit codes:
  0  All files are spec-compliant (or successfully repaired with --fix)
  1  Validation failed or file error

Examples:
  tm validate .tasks/active.tm.md
  tm validate --fix .tasks/active.tm.md
  tm validate .tasks/active.tm.md .tasks/future.tm.md
]])
    os.exit(0)
end

-- A fence delimiter: three or more of the same fence character at the very
-- start of the given string (§4.4.1 -- content never carries leading
-- whitespace outside a fence, so a payload's marker is always column 5;
-- a top-level fence's marker is column 1). Shares tmscan's fence-run
-- detection; the validator additionally needs the char/length pair to
-- track a specific fence's identity across the lines it stays open.
local function is_fence_marker(s)
    return tmscan.fence_opens(s) ~= nil
end

-- A CommonMark thematic break: three or more of the same character, among
-- -, _, and *, optionally interspersed with whitespace, and nothing else.
local function is_thematic_break(line)
    local stripped = line:gsub("%s", "")
    if #stripped < 3 then return false end
    local c = stripped:sub(1, 1)
    if c ~= "-" and c ~= "*" and c ~= "_" then return false end
    for i = 1, #stripped do
        if stripped:sub(i, i) ~= c then return false end
    end
    return true
end

-- The start of a malformed top-level task line or forbidden dash bullet.
-- Taskmark reserves '-' at column 0 strictly for task items (- [ ] / - [x]).
-- Other Markdown list markers (*, +, 1.) are permitted as top-level prose.
local function is_list_item_start(line)
    if line:match("^%- ") then return true end
    if line:match("^%-%[[ x]%] ") then return true end
    return false
end

-- A CommonMark raw-HTML-shaped line: an open/close tag, a comment, a
-- processing instruction, or a declaration -- not just a leading '<', which
-- CommonMark also uses for autolinks and plain "less than" text such as
-- "<3 days". §1.5 forbids rejecting anything CommonMark itself accepts.
local function is_raw_html_start(line)
    if line:match("^</?[A-Za-z]") then return true end
    if line:match("^<!%-%-") then return true end
    if line:match("^<%?") then return true end
    if line:match("^<!") then return true end
    return false
end

-- The last line of a leading pre-SPEC-TASKMARK-04 frontmatter block: line 1
-- is `---`, and a closing `---` (or `...`) follows with nothing but blank,
-- `#` comment, or `key: value` lines between. nil when there is none.
local function leading_frontmatter_end(lines)
    if lines[1] ~= "---" then return nil end
    for j = 2, #lines do
        local l = lines[j]
        if l == "---" or l == "..." then return j end
        if not (l:match("^%s*$") or l:match("^%s*#") or l:match("^[%w_%-]+:")) then
            return nil
        end
    end
    return nil
end

-- V3-V14: validate lines 1..#lines. `errors` collects {line, rule, msg}.
local function validate_body(lines, errors)
    local function add(line, rule, msg)
        errors[#errors + 1] = { line = line, rule = rule, msg = msg }
    end

    local in_payload = false
    local fence_open = false
    local fence_open_line = nil
    local fence_char, fence_len = nil, nil
    local prev_was_label = false
    local prev_kind = nil
    local in_list_item = false

    -- V14: frontmatter was removed in SPEC-TASKMARK-04. Report the block
    -- once and skip it, rather than flagging its `---` and `key: value`
    -- lines as a thematic break and a setext heading.
    local first = 1
    local fm_end = leading_frontmatter_end(lines)
    if fm_end then
        add(1, "V14", "frontmatter block (removed in SPEC-TASKMARK-04); delete lines 1-" .. fm_end ..
            " or run `tm validate --fix`")
        first = fm_end + 1
    end

    for i = first, #lines do
        local raw = lines[i]
        local kind, fields = tmscan.classify(raw)

        -- V7: a non-blank line with some leading whitespace whose first
        -- four columns are not four literal spaces.
        if not raw:match("^%s*$") then
            local lead = raw:match("^[ \t]*")
            if #lead > 0 and raw:sub(1, 4) ~= "    " then
                add(i, "V7", "payload line's first four columns are not four literal spaces")
            end
        end

        -- V3: a hard tab anywhere outside payload fence content. A line
        -- that classifies as "payload" is checked below, content-only and
        -- fence-aware; every other kind (heading, task, prose, blank) can
        -- never be fence content, so any tab at all is a violation.
        if kind ~= "payload" and raw:find("\t", 1, true) then
            add(i, "V3", "hard tab outside a fenced code block")
        end

        if kind == "payload" then
            -- A fence marker matches only against the fence it would open
            -- or close: the closing marker must share the opening line's
            -- character and be at least as long, and carry no info string
            -- (§4.4.3's two-readings guarantee, V12) -- otherwise a run
            -- of the *other* fence character is ordinary content.
            local opens_fence, closes_fence = false, false
            local opened_char, opened_len
            if fence_open then
                closes_fence = tmscan.fence_closes(fields.content, fence_char, fence_len)
            else
                opened_char, opened_len = tmscan.fence_opens(fields.content)
                if opened_char then opens_fence = true end
            end
            local marker = opens_fence or closes_fence
            local exempt = marker or fence_open

            -- V3: a hard tab in payload content, outside a fence.
            if not exempt and fields.content:find("\t", 1, true) then
                add(i, "V3", "hard tab in payload content outside a fenced code block")
            end

            if not exempt then
                -- V8: leading whitespace in payload content.
                -- SPEC-TASKMARK-04 allows up to 4 spaces of content indent (columns 5-8 total)
                -- if and only if continuing an active list item without an intervening blank line.
                local content_spaces = fields.content:match("^( *)")
                local num_spaces = content_spaces and #content_spaces or 0

                if num_spaces > 0 then
                    if in_list_item and num_spaces <= 4 and prev_kind ~= "blank" then
                        -- Allowed list continuation or sub-list under SPEC-TASKMARK-04.
                    else
                        add(i, "V8", "payload content has further leading whitespace outside a fenced code block")
                        in_list_item = false
                    end
                else
                    if fields.content:match("^[%-%*%+] ") or fields.content:match("^%d+[.)] ") then
                        in_list_item = true
                    else
                        in_list_item = false
                    end
                end

                -- V9: a task token inside a payload block.
                if fields.content:match("^%s*%- %[[ x]%] ") then
                    add(i, "V9", "task token inside a payload block")
                end
            end

            -- V10/V11: the labeled-field grammar. Applies to ordinary
            -- content and to a fence's *opening* marker line (which is
            -- itself freeform content that ends a run of labeled fields),
            -- but not to interior fence content or the closing marker --
            -- both were already inside the fence when this line arrived.
            if not fence_open then
                if fields.content:sub(1, 1) == ">" then
                    local key = fields.content:match("^> %*%*([A-Za-z][A-Za-z0-9_%-]*):%*%* (.*)$")
                    if key then
                        prev_was_label = true
                        in_list_item = false
                    elseif prev_was_label and fields.content:match("^> (.*)$") and not fields.content:match("^> %s*>") then
                        -- SPEC-TASKMARK-04 V10: multi-line labeled field continuation
                        prev_was_label = true
                        in_list_item = false
                    else
                        add(i, "V10", "payload line beginning with '>' does not match the labeled-field grammar")
                        prev_was_label = false
                        in_list_item = false
                    end
                else
                    if prev_was_label then
                        add(i, "V11", "freeform payload content directly follows a labeled field with no blank line between them")
                    end
                    prev_was_label = false
                end
            end

            if opens_fence then
                fence_char, fence_len = opened_char, opened_len
                fence_open, fence_open_line = true, i
                in_list_item = false
            elseif closes_fence then
                fence_open, fence_open_line, fence_char, fence_len = false, nil, nil, nil
                in_list_item = false
            end
            in_payload = true

        elseif kind == "blank" then
            prev_was_label = false
            in_list_item = false
            -- fence_open and in_payload carry through unchanged: a blank
            -- line never ends a payload, and inside a fence it is content.

        else -- heading or prose: the payload region, if any, ends here.
            if in_payload and fence_open then
                add(fence_open_line, "V12", "code fence opened in a payload block is not closed before the payload ends")
            end

            -- V13: CommonMark lazy continuation would absorb top-level
            -- prose directly beneath a task line or its payload.
            if (prev_kind == "payload" or prev_kind == "task") and kind == "prose" then
                add(i, "V13", "top-level prose directly follows a task or its payload with no blank line between them")
            end

            in_payload, fence_open, fence_open_line, prev_was_label = false, false, nil, false
            in_list_item = false
            fence_char, fence_len = nil, nil

            if kind == "prose" then
                local eq_underline = raw:match("^(=+)%s*$")
                local dash_underline = raw:match("^(%-+)%s*$")
                if (eq_underline or dash_underline) and prev_kind == "prose" then
                    add(i, "V4", "setext heading underline directly beneath a paragraph line")
                elseif is_fence_marker(raw) then
                    add(i, "V5", "forbidden top-level fenced code block")
                elseif raw:sub(1, 1) == ">" then
                    add(i, "V5", "forbidden top-level blockquote")
                elseif is_raw_html_start(raw) then
                    add(i, "V5", "forbidden top-level raw HTML")
                elseif is_thematic_break(raw) then
                    add(i, "V5", "forbidden top-level thematic break")
                elseif is_list_item_start(raw) then
                    add(i, "V6", "top-level list item is not a well-formed task token")
                end
            end
        end

        prev_kind = kind
    end

    if in_payload and fence_open then
        add(fence_open_line, "V12", "code fence opened in a payload block is not closed by end of file")
    end
end

-- Validate an array of line strings against SPEC-TASKMARK-04. Returns sorted errors table.
local function validate_lines(lines)
    local errors = {}
    validate_body(lines, errors)
    table.sort(errors, function(a, b) return a.line < b.line end)
    return errors
end

-- Automatically repair common formatting errors in Taskmark documents (V3, V6, V7, V8, V9, V10, V11, V13, V14).
-- Returns fixed_lines array and success boolean.
local function fix_document(lines)
    -- V14: drop a leading frontmatter block and the blank lines after it.
    local fm_end = leading_frontmatter_end(lines)
    if fm_end then
        local rest = {}
        local j = fm_end + 1
        while lines[j] and lines[j]:match("^%s*$") do j = j + 1 end
        for k = j, #lines do rest[#rest + 1] = lines[k] end
        lines = rest
    end

    local new_lines = {}
    local in_payload = false
    local fence_open = false
    local fence_char, fence_len = nil, nil
    local prev_was_label = false
    local prev_kind = nil
    local in_list_item = false

    local i = 1
    while i <= #lines do
        local raw = lines[i]
        local kind, fields = tmscan.classify(raw)

        if not fence_open and raw:find("\t", 1, true) then
            raw = raw:gsub("\t", "    ")
            kind, fields = tmscan.classify(raw)
        end

        if kind == "task" then
            in_payload = true
            fence_open = false
            prev_was_label = false
            in_list_item = false
            new_lines[#new_lines + 1] = raw

        elseif kind == "heading" then
            in_payload = false
            fence_open = false
            prev_was_label = false
            in_list_item = false
            new_lines[#new_lines + 1] = raw

        elseif kind == "blank" then
            prev_was_label = false
            in_list_item = false
            new_lines[#new_lines + 1] = ""

        elseif in_payload then
            if not raw:match("^%s*$") then
                local lead = raw:match("^[ \t]*")
                if #lead > 0 and raw:sub(1, 4) ~= "    " then
                    raw = "    " .. raw:gsub("^[ \t]*", "")
                    kind, fields = tmscan.classify(raw)
                end
            end

            if kind == "payload" then
                local opens_fence, closes_fence = false, false
                local opened_char, opened_len
                if fence_open then
                    closes_fence = tmscan.fence_closes(fields.content, fence_char, fence_len)
                else
                    opened_char, opened_len = tmscan.fence_opens(fields.content)
                    if opened_char then opens_fence = true end
                end

                if fence_open then
                    new_lines[#new_lines + 1] = raw
                    if closes_fence then
                        fence_open = false
                        fence_char, fence_len = nil, nil
                    end
                elseif opens_fence then
                    if prev_was_label then
                        new_lines[#new_lines + 1] = ""
                        prev_was_label = false
                    end
                    new_lines[#new_lines + 1] = raw
                    fence_open = true
                    fence_char, fence_len = opened_char, opened_len
                    in_list_item = false
                else
                    local content = fields.content

                    -- V10 / V11 check
                    if content:sub(1, 1) == ">" then
                        local key = content:match("^> %*%*([A-Za-z][A-Za-z0-9_%-]*):%*%* (.*)$")
                        if key then
                            prev_was_label = true
                            in_list_item = false
                            new_lines[#new_lines + 1] = "    " .. content
                        elseif prev_was_label and content:match("^> (.*)$") and not content:match("^> %s*>") then
                            -- SPEC-TASKMARK-04: Multi-line labeled field continuation
                            prev_was_label = true
                            in_list_item = false
                            new_lines[#new_lines + 1] = "    " .. content
                        else
                            local prose = content:gsub("^>%s*", "")
                            if prev_was_label then
                                new_lines[#new_lines + 1] = ""
                                prev_was_label = false
                            end
                            new_lines[#new_lines + 1] = "    " .. prose
                            in_list_item = false
                        end
                    else
                        if prev_was_label then
                            new_lines[#new_lines + 1] = ""
                            prev_was_label = false
                        end

                        -- V8: check leading whitespace in payload content
                        local content_spaces = content:match("^( *)")
                        local num_spaces = content_spaces and #content_spaces or 0

                        if num_spaces > 0 then
                            if in_list_item and num_spaces <= 4 and prev_kind ~= "blank" then
                                -- SPEC-TASKMARK-04: Valid sub-list or continuation indent! Keep content.
                            else
                                content = content:gsub("^[ \t]+", "")
                                if content:match("^[%-%*%+] ") or content:match("^%d+[.)] ") then
                                    in_list_item = true
                                else
                                    in_list_item = false
                                end
                            end
                        else
                            if content:match("^[%-%*%+] ") or content:match("^%d+[.)] ") then
                                in_list_item = true
                            else
                                in_list_item = false
                            end
                        end

                        -- V9: task token inside payload
                        if content:match("^%- %[[ x]%] ") then
                            content = content:gsub("^%- %[[ x]%] ", "- ")
                        elseif content:match("^(%s+)%- %[[ x]%] ") then
                            content = content:gsub("^(%s+)%- %[[ x]%] ", "%1- ")
                        end

                        new_lines[#new_lines + 1] = "    " .. content
                    end
                end
            else
                in_payload = false
                fence_open = false
                prev_was_label = false
                in_list_item = false
                i = i - 1
            end
        else
            -- Top-level prose line
            if kind == "prose" then
                if raw:match("^%- %[ %] ") then
                    raw = raw:gsub("^%- %[ %] ", "- [ ] ")
                elseif raw:match("^%- %[[Xx]%] ") then
                    raw = raw:gsub("^%- %[[Xx]%] ", "- [x] ")
                elseif raw:match("^%- %[%] ") then
                    raw = raw:gsub("^%- %[%] ", "- [ ] ")
                elseif raw:match("^%- %(([A-Z])%) ") then
                    raw = raw:gsub("^%- %(([A-Z])%) ", "- [ ] (%1) ")
                elseif raw:match("^%-%[[ x]%] ") then
                    raw = raw:gsub("^%-%[([ x])%] ", "- [%1] ")
                elseif raw:match("^%- ") then
                    raw = raw:gsub("^%- ", "* ")
                elseif raw:match("^• ") then
                    raw = raw:gsub("^• ", "* ")
                end
                -- V13: separate prose from a task or payload line directly
                -- above it. Judged on the lines actually emitted, since a
                -- payload-ending line arrives here on its second pass.
                local prev = new_lines[#new_lines]
                local prev_emitted = prev and tmscan.classify(prev)
                if tmscan.classify(raw) == "prose"
                    and (prev_emitted == "payload" or prev_emitted == "task") then
                    new_lines[#new_lines + 1] = ""
                end
            end
            new_lines[#new_lines + 1] = raw
        end
        prev_kind = kind
        i = i + 1
    end

    return new_lines, true
end

local function run(args)
    args = args or arg or {}

    local files = {}
    local fix_mode = false
    local end_of_options = false
    for _, a in ipairs(args) do
        if not end_of_options and (a == "-h" or a == "--help") then
            show_help()
        elseif not end_of_options and a == "--fix" then
            fix_mode = true
        elseif not end_of_options and a == "--" then
            end_of_options = true
        else
            files[#files + 1] = a
        end
    end

    if #files == 0 then
        files = { tmconfig.resolve({}).active_path }
    end

    local TERM_RESET  = "\27[0m"
    local TERM_RED    = "\27[31m"
    local TERM_GREEN  = "\27[32m"
    local TERM_YELLOW = "\27[33m"

    local total_errors = 0
    local had_file_error = false

    local function process(file)
        local f = io.open(file, "r")
        if not f then
            print(TERM_RED .. "Error: Target task file '" .. file .. "' not found." .. TERM_RESET)
            if #files == 1 then
                print("Usage: tm validate [file...]")
                print("       tm validate --help for details")
            end
            had_file_error = true
        else
            local raw_content = f:read("*a")
            f:close()

            local lines = tmscan.lines_of(raw_content)
            local errors = validate_lines(lines)

            if #errors == 0 then
                print(string.format("%s[PASS]%s %s conforms to SPEC-TASKMARK-04.", TERM_GREEN, TERM_RESET, file))
            elseif fix_mode then
                local fixed_lines, ok = fix_document(lines)
                local remaining_errors = validate_lines(fixed_lines)
                if #remaining_errors == 0 then
                    -- Write back through the shared atomic writer, keeping
                    -- the document's own newline style.
                    local nl = tmscan.detect_newline(raw_content)
                    local ok_w, werr = tmio.write_file_atomic(file, table.concat(fixed_lines, nl) .. nl)
                    if not ok_w then tmio.die(werr) end
                    print(string.format("%s[FIXED]%s %s (repaired %d error(s); now conforms to SPEC-TASKMARK-04).", TERM_YELLOW, TERM_RESET, file, #errors))
                else
                    for _, e in ipairs(remaining_errors) do
                        if #files > 1 then
                            print(string.format("%s[FAIL]%s %s: Line %d: %s: %s", TERM_RED, TERM_RESET, file, e.line, e.rule, e.msg))
                        else
                            print(string.format("%s[FAIL]%s Line %d: %s: %s", TERM_RED, TERM_RESET, e.line, e.rule, e.msg))
                        end
                    end
                    total_errors = total_errors + #remaining_errors
                end
            else
                for _, e in ipairs(errors) do
                    if #files > 1 then
                        print(string.format("%s[FAIL]%s %s: Line %d: %s: %s", TERM_RED, TERM_RESET, file, e.line, e.rule, e.msg))
                    else
                        print(string.format("%s[FAIL]%s Line %d: %s: %s", TERM_RED, TERM_RESET, e.line, e.rule, e.msg))
                    end
                end
                total_errors = total_errors + #errors
            end
        end
    end

    for _, file in ipairs(files) do
        if fix_mode then
            -- --fix is a read-modify-write: hold the directory lock across it.
            tmio.with_lock(file:match("^(.*)/[^/]+$") or ".", process, file)
        else
            process(file)
        end
    end

    if total_errors > 0 then
        print(string.format("%sValidation failed with %d error(s).%s", TERM_RED, total_errors, TERM_RESET))
        os.exit(1)
    elseif had_file_error then
        os.exit(1)
    end

    os.exit(0)
end

-- When invoked directly (not required as a module), run immediately.
if arg and arg[0] and arg[0]:match("tmval%.lua$") then
    run(arg)
end

return { run = run, validate_lines = validate_lines, fix_document = fix_document }
