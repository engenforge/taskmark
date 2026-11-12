#!/usr/bin/env lua
-- tests/tmid_test.lua — unit tests for tmid.lua (SPEC-TASKMARK-05 §4.3.3
-- task identifiers and the Depends field).

local script_dir = (arg[0] or "./tests/tmid_test.lua"):match("^(.*)/[^/]+$") or "."
package.path = script_dir .. "/../src/?.lua;" .. package.path

local tmid   = require("tmid")
local tmio   = require("tmio")
local tmscan = require("tmscan")

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

local function write(path, body)
    local f = assert(io.open(path, "w"))
    f:write(body)
    f:close()
end

-- ── of: the identifier on a task line ─────────────────────────────────────

check("of", "trailing id word", tmid.of("- [ ] +api Add rate limiting id:k7q2x") == "k7q2x")
check("of", "leading id word", tmid.of("id:k7q2x Add rate limiting") == "k7q2x")
check("of", "mid-line id word", tmid.of("- [x] (A) Fix id:m3x8a the parser") == "m3x8a")
check("of", "no id", tmid.of("- [ ] Add rate limiting") == nil)
check("of", "four characters is the minimum", tmid.of("Task id:abcd") == "abcd" and tmid.of("Task id:abc") == nil)
check("of", "longer ids are accepted", tmid.of("Task id:z0114abc") == "z0114abc")
check("of", "uppercase or punctuation is not an id",
    tmid.of("Task id:K7Q2X") == nil and tmid.of("Task id:k7-2x") == nil)
check("of", "must be a whole word", tmid.of("Task grid:k7q2x") == nil and tmid.of("Task id:k7q2x.") == nil)
check("of", "first id word wins", tmid.of("Task id:aaaaa id:bbbbb") == "aaaaa")

-- ── refs: identifiers cited in a Depends value ────────────────────────────

do
    local r = tmid.refs("id:m3x8a, id:k7q2x and valid:zzzzz (see id:abcd).")
    check("refs", "collects every id reference in order",
        #r == 3 and r[1] == "m3x8a" and r[2] == "k7q2x" and r[3] == "abcd", table.concat(r, " "))
    check("refs", "no references", #tmid.refs("the parser task") == 0)
end

-- ── generate: random draws ────────────────────────────────────────────────

do
    local id = tmid.generate()
    check("generate", "five characters from the alphabet",
        id and #id == 5 and id:match("^[0-9a-hjkmnp-tv-z]+$") ~= nil, id)
    check("generate", "alphabet has 32 symbols and no look-alikes",
        #tmid.ALPHABET == 32 and not tmid.ALPHABET:find("[ilou]"))
    local seen, distinct = {}, 0
    for _ = 1, 50 do
        local d = tmid.generate()
        if not seen[d] then seen[d] = true; distinct = distinct + 1 end
    end
    check("generate", "draws differ", distinct >= 49, distinct)
    check("generate", "maps bytes onto the alphabet",
        tmid.generate(function() return string.char(0, 1, 31, 32, 255) end) == "01z0z")
    local none, err = tmid.generate(function() return nil end)
    check("generate", "no entropy source is an error, not a weak id", none == nil and err ~= nil)
end

-- ── fresh: redraw while taken ─────────────────────────────────────────────

do
    local draws = { "aaaaa", "bbbbb", "ccccc" }
    local n = 0
    local function draw() n = n + 1; return draws[n] end
    local texts = { "- [x] Old task id:aaaaa\n", "    > **Depends:** id:bbbbb\n" }
    check("fresh", "skips ids found anywhere, including references", tmid.fresh(texts, draw) == "ccccc")
    check("fresh", "taken is a plain substring search",
        tmid.taken("aaaaa", texts) and not tmid.taken("ddddd", texts))
    local stuck, err = tmid.fresh({ "id:aaaaa" }, function() return "aaaaa" end)
    check("fresh", "gives up rather than loop forever", stuck == nil and err ~= nil)
end

-- ── task_files / duplicates / status over a task directory ────────────────

do
    local dir = string.format("/tmp/tm_id_test_%d_%s", os.time(), tmio.unique_token())
    tmio.mkdir_p(dir .. "/archive/2026")
    write(dir .. "/active.tm.md", "# S\n\n- [ ] One id:aaaaa\n\n- [ ] Two id:bbbbb\n    > **Depends:** id:aaaaa\n")
    write(dir .. "/future.tm.md", "# P\n\n- [ ] Copy of one id:aaaaa\n")
    write(dir .. "/completed.tm.md", "# C\n\n- [x] Done id:ccccc\n    > **Notes:** follows id:bbbbb\n")
    write(dir .. "/archive/2026/2026-01.tm.md", "# A\n\n- [x] Old id:ddddd\n")
    local cfg = {
        tasks_dir = dir, archive_dir = "archive",
        active_path = dir .. "/active.tm.md", future_path = dir .. "/future.tm.md",
        completed_path = dir .. "/completed.tm.md",
    }

    local files = tmid.task_files(cfg)
    check("task_files", "active, future, completed, then archive files",
        #files == 4 and files[1] == cfg.active_path and files[4]:match("archive/2026/2026%-01%.tm%.md$") ~= nil,
        table.concat(files, " "))
    os.remove(dir .. "/future.tm.md")
    check("task_files", "missing files are left out", #tmid.task_files(cfg) == 3)
    write(dir .. "/future.tm.md", "# P\n\n- [ ] Copy of one id:aaaaa\n")

    local dups = tmid.duplicates(files)
    check("duplicates", "an id on two task lines is reported once, with both places",
        #dups == 1 and dups[1].id == "aaaaa" and #dups[1].places == 2
        and dups[1].places[1].line == 3 and dups[1].places[2].path == cfg.future_path)
    check("duplicates", "a reference is not a second definition", (function()
        for _, d in ipairs(dups) do if d.id == "bbbbb" then return false end end
        return true
    end)())

    check("status", "pending task", tmid.status("bbbbb", files) == "pending")
    check("status", "completed task", tmid.status("ccccc", files) == "done")
    check("status", "archived task", tmid.status("ddddd", files) == "done")
    check("status", "unknown id", tmid.status("zzzzz", files) == nil)

    os.execute("rm -rf " .. tmio.shell_quote(dir))
end

-- ── depends: the Depends field of a task ──────────────────────────────────

do
    local lines = tmscan.lines_of([[
- [ ] Two id:bbbbb
    > **Created:** 2026-11-12
    > **Depends:** id:aaaaa,
    > id:ccccc

    ```
    > **Depends:** id:fence
    ```

- [ ] Three
]])
    local tasks = tmscan.tasks(lines)
    local d = tmid.depends(lines, tasks[1])
    check("depends", "reads the field and its continuation lines, not fenced text",
        #d == 2 and d[1] == "aaaaa" and d[2] == "ccccc", table.concat(d, " "))
    check("depends", "a task without the field depends on nothing", #tmid.depends(lines, tasks[2]) == 0)
end

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
