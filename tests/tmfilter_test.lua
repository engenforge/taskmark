#!/usr/bin/env lua
-- tests/tmfilter_test.lua — unit + round-trip tests for tmfilter.lua
-- (SPEC-TASKMARK-05 §8.1 indent/dedent payload filters).

local script_dir = (arg[0] or "./tests/tmfilter_test.lua"):match("^(.*)/[^/]+$") or "."
local tmfilter_path = script_dir .. "/../src/tmfilter.lua"

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

-- Run `lua tmfilter.lua <args>` with `input` on stdin. Returns stdout, exit code.
local function run(args, input)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    f:write(input)
    f:close()
    local cmd = string.format("lua %s %s < %s 2>&1; echo __EXIT__$?", tmfilter_path, args, tmp)
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()
    os.remove(tmp)
    local exit_code = tonumber(output:match("__EXIT__(%d+)")) or -1
    output = output:gsub("__EXIT__%d+\n?$", "")
    return output, exit_code
end

-- ── indent ───────────────────────────────────────────────────────────────

do
    local out, code = run("indent", "a\nb\n")
    check("indent", "prefixes non-blank lines with four spaces", out == "    a\n    b\n")
    check("indent", "exit 0", code == 0)
end

do
    local out = run("indent", "a\n\nb\n")
    check("indent", "blank line emitted genuinely empty, not four trailing spaces", out == "    a\n\n    b\n")
end

do
    local out = run("indent", "a\n\tb\n")
    check("indent", "tabs in content are preserved verbatim", out == "    a\n    \tb\n")
end

do
    local out = run("indent sh", "echo hi\n")
    check("indent", "info string wraps output in a fenced payload",
        out == "    ```sh\n    echo hi\n    ```\n")
end

-- ── dedent ───────────────────────────────────────────────────────────────

do
    local out, code = run("dedent", "    a\n    b\n")
    check("dedent", "removes exactly four leading spaces", out == "a\nb\n")
    check("dedent", "exit 0", code == 0)
end

do
    local out = run("dedent", "    a\n\n    b\n")
    check("dedent", "blank lines pass through untouched", out == "a\n\nb\n")
end

do
    local out, code = run("dedent", "  a\n")
    check("dedent", "a non-blank line lacking the full prefix exits non-zero", code ~= 0)
    check("dedent", "does not print a truncated (wrong) line to stdout", not out:match("^a$"))
end

do
    local out, code = run("dedent --fence", "    ```sh\n    echo hi\n    ```\n")
    check("dedent", "--fence drops the opening and closing fence markers", out == "echo hi\n")
    check("dedent", "--fence exit 0", code == 0)
end

-- ── round-trip ───────────────────────────────────────────────────────────

do
    local input = "a\n\n\tb\n"
    local indented = run("indent", input)
    local roundtripped = run("dedent", indented)
    check("round-trip", "dedent(indent(x)) == x for tabs/blank/plain mixed input", roundtripped == input)
end

do
    local input = "line with trailing spaces   \n\n\n   only spaces   \nlast line, no trailing newline"
    local indented = run("indent", input .. "\n")
    local roundtripped = run("dedent", indented)
    check("round-trip", "byte-exact for trailing whitespace and whitespace-only lines",
        roundtripped == input .. "\n")
end

do
    local input = "echo hi\nprintf 'x'\n"
    local indented = run("indent go", input)
    local roundtripped = run("dedent --fence", indented)
    check("round-trip", "dedent --fence(indent info) == original content", roundtripped == input)
end

-- ── help ─────────────────────────────────────────────────────────────────

do
    local out, code = run("-h", "")
    check("help", "-h exits 0", code == 0)
    check("help", "-h prints usage", out:match("indent") ~= nil and out:match("dedent") ~= nil)
end

-- ── Summary ──────────────────────────────────────────────────────────────

print(string.format("\nResults: %d passed, %d failed, %d total\n", passed, failed, passed + failed))
os.exit(failed > 0 and 1 or 0)
