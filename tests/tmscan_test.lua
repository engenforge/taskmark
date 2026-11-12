#!/usr/bin/env lua
-- tests/tmscan_test.lua — unit tests for tmscan.lua (SPEC-TASKMARK-05 §7
-- single-pass line scanner).

local script_dir = (arg[0] or "./tests/tmscan_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmscan = require("tmscan")

local passed, failed = 0, 0

local function check(group, name, ok, detail)
    if ok then
        passed = passed + 1
        print(string.format("[PASS] %s: %s", group, name))
    else
        failed = failed + 1
        print(string.format("[FAIL] %s: %s%s", group, name, detail and (" -- " .. detail) or ""))
    end
end

-- ── classify: blank ──────────────────────────────────────────────────────

do
    local kind = tmscan.classify("")
    check("classify blank", "empty line", kind == "blank")
end

do
    local kind = tmscan.classify("    ")
    check("classify blank", "spaces-only line (exactly four)", kind == "blank")
end

do
    local kind = tmscan.classify("      ")
    check("classify blank", "spaces-only line (more than four)", kind == "blank")
end

-- ── classify: heading ────────────────────────────────────────────────────

do
    local kind, fields = tmscan.classify("# Current Sprint")
    check("classify heading", "level 1", kind == "heading" and fields.level == 1)
    check("classify heading", "text captured", fields.text == "Current Sprint")
end

do
    local kind, fields = tmscan.classify("### Sub Heading")
    check("classify heading", "level 3", kind == "heading" and fields.level == 3)
end

do
    local kind = tmscan.classify("#no space")
    check("classify heading", "no space after hashes is not a heading", kind ~= "heading")
end

-- ── classify: task ───────────────────────────────────────────────────────

do
    local kind, fields = tmscan.classify("- [ ] Plain pending task")
    check("classify task", "pending token recognized", kind == "task" and fields.done == false)
    check("classify task", "no priority captured", fields.priority == nil)
    check("classify task", "description captured", fields.description == "Plain pending task")
end

do
    local kind, fields = tmscan.classify("- [x] Done task")
    check("classify task", "completed token recognized", kind == "task" and fields.done == true)
end

do
    local kind, fields = tmscan.classify("- [ ] (A) Prioritized task")
    check("classify task", "priority captured", kind == "task" and fields.priority == "A")
    check("classify task", "description excludes priority", fields.description == "Prioritized task")
end

do
    local kind = tmscan.classify("- [X] Uppercase X is not a valid token")
    check("classify task", "uppercase X is not accepted as a task", kind ~= "task")
end

do
    local kind = tmscan.classify("- not a task token")
    check("classify task", "plain bullet is not a task", kind ~= "task")
end

-- ── classify: payload ────────────────────────────────────────────────────

do
    local kind, fields = tmscan.classify("    > **Context:** why this matters")
    check("classify payload", "exactly four spaces recognized", kind == "payload")
    check("classify payload", "prefix is four spaces", fields.prefix == "    ")
    check("classify payload", "content starts at column 5", fields.content == "> **Context:** why this matters")
end

do
    local kind, fields = tmscan.classify("      six spaces of content")
    check("classify payload", "more than four leading spaces still splits at column four", kind == "payload")
    check("classify payload", "extra indentation stays in content, uninspected", fields.content == "  six spaces of content")
end

do
    local kind = tmscan.classify("   three spaces only")
    check("classify payload", "fewer than four leading spaces is not a payload", kind ~= "payload")
end

-- ── classify: prose ──────────────────────────────────────────────────────

do
    local kind, fields = tmscan.classify("Just a paragraph of text.")
    check("classify prose", "column-0 non-matching line is prose", kind == "prose")
    check("classify prose", "text preserved", fields.text == "Just a paragraph of text.")
end

do
    local kind = tmscan.classify("   three leading spaces of prose-ish text")
    check("classify prose", "under-indented line falls through to prose", kind == "prose")
end

-- ── iter: heading and task attribution ───────────────────────────────────

do
    local lines = {
        "# Current Sprint",
        "",
        "- [ ] First task",
        "    > **Context:** detail",
        "- [x] Second task",
    }
    local seen = {}
    for i, kind, fields, heading, task in tmscan.iter(lines) do
        seen[i] = { kind = kind, heading = heading, task = task }
    end
    check("iter", "heading tracked for lines after it", seen[3].heading == "Current Sprint")
    check("iter", "task tracked for its own payload line", seen[4].task.description == "First task")
    check("iter", "new task line updates the tracked task", seen[5].task.description == "Second task")
end

do
    local lines = { "- [ ] Orphan task", "Column-0 prose ends the payload context", "    > **Notes:** stray" }
    local seen = {}
    for i, kind, fields, heading, task in tmscan.iter(lines) do
        seen[i] = task
    end
    check("iter", "prose line clears the tracked task", seen[2] == nil)
end

do
    local lines = { "# H1", "- [ ] Task", "## H2", "    > **Notes:** stray" }
    local seen = {}
    for i, kind, fields, heading, task in tmscan.iter(lines) do
        seen[i] = { heading = heading, task = task }
    end
    check("iter", "heading line clears the tracked task", seen[4].task == nil)
    check("iter", "heading line updates the tracked heading", seen[4].heading == "H2")
end

-- ── iter: fence tracking ─────────────────────────────────────────────────

do
    local lines = {
        "- [ ] Task with a fence",
        "    ```lua",
        "    local x = 1",
        "    ```",
        "    trailing content",
    }
    local fence_state = {}
    for i, kind, fields, heading, task, fence_open in tmscan.iter(lines) do
        fence_state[i] = fence_open
    end
    check("iter", "fence opens on the opening backtick line", fence_state[2] == true)
    check("iter", "fence stays open on content inside it", fence_state[3] == true)
    check("iter", "fence closes on the matching closing line", fence_state[4] == false)
    check("iter", "fence state stays closed after the fence", fence_state[5] == false)
end

do
    local lines = { "- [ ] Task", "    ~~~", "    tilde fence content", "    ~~~" }
    local fence_state = {}
    for i, kind, fields, heading, task, fence_open in tmscan.iter(lines) do
        fence_state[i] = fence_open
    end
    check("iter", "tilde fences toggle the same way as backtick fences", fence_state[2] == true and fence_state[4] == false)
end

do
    local lines = { "- [ ] Task one", "    ```", "    unterminated fence", "- [ ] Task two" }
    local fence_state = {}
    for i, kind, fields, heading, task, fence_open in tmscan.iter(lines) do
        fence_state[i] = fence_open
    end
    check("iter", "a new task resets fence state even if the prior fence was left open", fence_state[4] == false)
end

-- ── tasks() ──────────────────────────────────────────────────────────────

do
    local lines = {
        "# Current Sprint",
        "",
        "- [ ] (A) Task with a payload",
        "    > **Context:** detail one",
        "    > **Notes:** detail two",
        "",
        "- [x] Task with no payload",
        "- [ ] Task with a blank-interleaved payload",
        "    freeform line one",
        "",
        "    freeform line two",
        "# Next Section",
    }
    local tasks = tmscan.tasks(lines)
    check("tasks", "finds every task line", #tasks == 3)

    check("tasks", "first task fields", tasks[1].line == 3 and tasks[1].done == false and tasks[1].priority == "A"
        and tasks[1].description == "Task with a payload" and tasks[1].heading == "Current Sprint")
    check("tasks", "first task payload range", tasks[1].payload_start == 4 and tasks[1].payload_end == 6)

    check("tasks", "second task has no payload", tasks[2].payload_start == nil and tasks[2].payload_end == nil)

    check("tasks", "third task payload spans interleaved blank lines", tasks[3].payload_start == 9 and tasks[3].payload_end == 11)
end

do
    local lines = { "- [ ] Task", "", "- [ ] Next task, separated only by a blank line" }
    local tasks = tmscan.tasks(lines)
    check("tasks", "a lone blank separator is not treated as a payload", tasks[1].payload_start == nil)
    check("tasks", "the second task is still found at its own line", tasks[2].line == 3)
end

do
    local lines = { "- [ ] Task", "    payload line", "", "" }
    local tasks = tmscan.tasks(lines)
    check("tasks", "trailing blank lines at end of file extend the payload", tasks[1].payload_start == 2 and tasks[1].payload_end == 4)
end

-- ── detect_newline ───────────────────────────────────────────────────────

do
    check("detect_newline", "CRLF detected", tmscan.detect_newline("a\r\nb\r\n") == "\r\n")
    check("detect_newline", "LF detected", tmscan.detect_newline("a\nb\n") == "\n")
    check("detect_newline", "nil content defaults to LF", tmscan.detect_newline(nil) == "\n")
end

-- ── lines_of ─────────────────────────────────────────────────────────────

do
    local lines = tmscan.lines_of("a\nb\nc\n")
    check("lines_of", "splits trailing-newline content", #lines == 3 and lines[1] == "a" and lines[3] == "c")
end

do
    local lines = tmscan.lines_of("a\nb")
    check("lines_of", "splits content with no trailing newline", #lines == 2 and lines[2] == "b")
end

do
    check("lines_of", "empty string yields empty array", #tmscan.lines_of("") == 0)
end

-- ── parse_iso8601 ────────────────────────────────────────────────────────

do
    check("parse_iso8601", "bare date parses", tmscan.parse_iso8601("2026-03-01") == 1772323200)
    check("parse_iso8601", "full timestamp parses",
        tmscan.parse_iso8601("2026-03-01T15:30:45Z") == 1772323200 + 15 * 3600 + 30 * 60 + 45)
end

do
    check("parse_iso8601", "rejects month 13", tmscan.parse_iso8601("2026-13-45") == nil)
    check("parse_iso8601", "rejects Feb 29 on a non-leap year", tmscan.parse_iso8601("2026-02-29") == nil)
    check("parse_iso8601", "accepts Feb 29 on a leap year", tmscan.parse_iso8601("2000-02-29") ~= nil)
    check("parse_iso8601", "rejects garbage", tmscan.parse_iso8601("not-a-date") == nil)
    check("parse_iso8601", "nil input returns nil", tmscan.parse_iso8601(nil) == nil)
end

-- ── task_hash ────────────────────────────────────────────────────────────

do
    local h1 = tmscan.task_hash("- [ ] (A) Runtime hardening: collision-safe atomic writes")
    local h2 = tmscan.task_hash("- [x] (A) Runtime hardening: collision-safe atomic writes")
    local h3 = tmscan.task_hash("(A) Runtime hardening: collision-safe atomic writes")
    local h4 = tmscan.task_hash("  - [ ]   (A) Runtime hardening: collision-safe atomic writes  ")

    check("task_hash", "returns 8-character hex string", type(h1) == "string" and #h1 == 8 and h1:match("^%x+$") ~= nil)
    check("task_hash", "preserves hash across pending and completed checkbox state", h1 == h2)
    check("task_hash", "matches bare summary without checkbox", h1 == h3)
    check("task_hash", "ignores leading and trailing whitespace", h1 == h4)

    local diff_hash = tmscan.task_hash("- [ ] Different task")
    check("task_hash", "different tasks have different hashes", h1 ~= diff_hash)

    local sample = tmscan.lines_of("# Header\n\n- [ ] (A) Test task\n    > **Context:** info\n")
    local t = tmscan.tasks(sample)[1]
    check("tasks", "task record carries hash", t and t.hash == tmscan.task_hash(sample[3]))
    check("tasks", "task record carries summary", t and t.summary == "(A) Test task")
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
