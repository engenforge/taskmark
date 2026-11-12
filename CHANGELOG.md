# Changelog

All notable changes to Taskmark and the underlying task specification are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- Task identifiers: `tm add` stamps each new task with a random five-character identifier on its line (`id:k7q2x`) that never changes and is never reused, and `tm id` stamps pending tasks that lack one. `tm list` shows the identifier as the task's handle, and `tm done` and `tm move` accept it. An identifier already in the text, such as one carried over from an existing scheme, is kept, and refused if already in use.
- `tm next` prints the task to start: the first pending task with no unmet `Depends`, flagged priorities first.
- `tm add` and `tm move` take `--before TASK` and `--after TASK` to place a task next to another, across headings.
- `tm check-shas` reports `git:<sha>` citations that no longer name a commit, or with `--branch REF` are not reachable from it; `tm remap OLD NEW [OLD NEW...]` replaces citations of rewritten commits in every task file.
- `tm list` and `tm next` filter by tag: `tm list +api @backend --not @review`.
- `tm validate` prints non-fatal `[WARN]` lines for a malformed `Created`, `Due`, or `Completed` value, a `**Key:**` inside a field's value, and an identifier carried by two tasks. Completed tasks are checked only for their `Completed` stamp.

### Changed
- **Specification (SPEC-TASKMARK-05):** every SPEC-TASKMARK-04 document still conforms; the grammar and rules V3-V14 are unchanged. Adds the optional task identifier (§4.3.3) and the registered `Depends` key (§4.4.2). §5.1 now states that position is the order of work, how a priority flag and dependencies affect it, and the `@review` convention for work awaiting review. §6.1 clarifies that "fits on one screen" means the task lines, and that headings divide work by time while other axes are tags. §4.3.3 also covers carrying over an existing numbering scheme and adopting identifiers in a project with completed work; §4.4.2 says a `Depends` value may carry free text, which tools ignore. §5.1 covers a review that sends a task back, that headings do not gate selection, and where a new task goes. §10.3 permits citing an identifier in a commit message and describes remapping stamped hashes after a squash.
- `tm validate` colours its output only when standard output is a terminal and `NO_COLOR` is unset; piped and captured output is plain text.
- Rule V7's message for an indented line outside a task names the likely cause (a wrapped prose or list line) instead of calling it a payload line.
- Local `.taskmarkrc` configuration is now discovered by searching upward from the current working directory to the enclosing Git repository or worktree root. Relative paths inside `.taskmarkrc` resolve relative to the directory containing it, and default task paths inside a Git worktree resolve relative to the repository root.

### Fixed
- `tm init --orphan` no longer writes a redundant `.taskmarkrc` for the default `.tasks` directory.
- Commands operating on a nonexistent task directory fail immediately reporting that the directory does not exist, rather than sleeping through lock retries and falsely reporting that the directory is locked by another process.

---

## [0.4.0] - 2026-11-08

### Added
- `tm list`, `tm add`, `tm done`, and `tm move` for editing tasks from the command line, addressed by short handles derived from each task's text.
- `tm init --orphan [BRANCH]` and `tm sync` to keep task files on a separate Git branch mounted at `.tasks/`.
- Rule V14 reports leftover frontmatter in pre-0.4 files; `tm validate --fix` removes it.

### Changed
- **Specification (SPEC-TASKMARK-04):** task files are pure CommonMark with no frontmatter; hub-and-spoke concepts removed.
- Rule V13 requires a blank line between a task (or its payload) and following prose.
- Default task directory is `.tasks/` (was `doc/tasks/`, still used when it is the only one present).
- `completed.tm.md` and archive files are newest first; sweeps bucket under `## YYYY-MM`, or `## Sprint <id>` with `tm sweep --sprint <id>`.
- `tm archive` keeps the 2 newest sections in `completed.tm.md` (was 10).
- Commands that modify task files lock the task directory, so concurrent runs no longer lose updates.

### Removed
- `tm rotate` (use `tm sweep --sprint <id>`).
- Rules V1/V2 and the unused hub configuration keys.

### Fixed
- A failed write never replaces a task file, and concurrent writers no longer share a temp file.
- `tm validate --fix` preserves CRLF line endings.
- Symlinked task files keep their link when rewritten.
- The installed `VERSION` file is readable by all users.

---

## [0.3.0] - 2026-10-27

### Changed
- **Grammar Relaxation (SPEC-TASKMARK-03):**
  - **Rule V6 (Prose Lists):** Relaxed to permit top-level prose bullet lists (`*`, `+`) and ordered lists (`1.`) alongside standard tasks.
  - **Rule V8 (Payload Sub-lists):** Relaxed to allow sub-lists (indented 2 spaces relative to list items) and hanging continuation lines within active task payloads.
  - **Rule V10 (Multi-line Labeled Fields):** Relaxed to allow multi-line labeled fields using continuation lines prefixed with `    > `.
- **Auto-Repair Engine:** Updated `tm validate --fix` to normalize loose bullets and legacy Unicode `•` bullets to `*`, while preserving valid sub-lists and multi-line labeled fields without flattening.
- Updated specification ([`doc/taskmark_spec.md`](doc/taskmark_spec.md)), man pages ([`doc/tm.1.scd`](doc/tm.1.scd)), and tests to reference `SPEC-TASKMARK-03`.

---

## [0.2.1] - 2026-10-27

### Added
- **Validation Auto-Repair:** Introduced `tm validate --fix` to automatically repair common formatting inconsistencies (e.g. indentation, loose bullet styles).
- **Batch Validation:** Permitted `tm validate` to accept multiple file arguments in a single invocation.

---

## [0.2.0] - 2026-09-02

### Changed
- **Specification Migration (SPEC-TASKMARK-02):**
  - Standardized task file extension to `.tm.md` (`active.tm.md`, `future.tm.md`, `completed.tm.md`).
  - Migrated frontmatter from fenced JSON to a flat `key: value` subset (YAML-compatible) delimited by `---`.
  - Replaced section-level sprint rotation with task-level sweep (`tm sweep`) and sprint rollover (`tm rotate`).
  - Enforced a strict 4-space payload indentation rule aligned with list item content.
- **Pure Lua Single-Pass Scanner:** Introduced `src/tmscan.lua` to classify document lines in a single pass without building an AST or retaining whole files in memory.
- **Zero-Dependency Runtime:** Removed runtime AST parsing dependencies (`cmark-lua` / `dkjson.lua`). Lua C bindings are retained solely for the test suite's CommonMark oracle (`tests/commonmark_test.lua`).
- **Configuration Hierarchy:** Introduced two-file, per-key configuration resolution across global (`$XDG_CONFIG_HOME/taskmark/config`) and local (`.taskmarkrc`) config files.
- **Payload Filters:** Added `tm indent` and `tm dedent` payload filter subcommands for clean shell and scripting integration.

---

## [0.1.0] - 2026-08-27

### Added
- **Universal CLI (`tm`):** Introduced the installable `tm` command-line dispatcher with subcommands for `validate`, `sweep`, `rotate`, `archive`, and `init`.
- **System Installation:** Added `Makefile` targets for `install`, `uninstall`, and reproducible release packaging (`make dist`, `make dist-bin`).
- **Documentation:** Added `tm(1)` manual page authored in `scdoc` with roff generation.
- **Standards Adaptation:** Adapted `todo.txt` metadata conventions (priority flags `(A)`, tags `+project`, contexts `@context`, and due dates `due:YYYY-MM-DD`).
- **Archive Automation:** Automated aging of completed sprint sections into `archive/<YYYY>/<YYYY-MM>.tm.md`.

---

## Pre-Release / Specification Genesis - 2026-06-30 to 2026-08-26

- **2026-06-30:** Project inception and initial commit of `SPEC-MDTASK-01` specification, test corpus, and `tmval.lua` command-line validator.
- **2026-07-07:** Introduced the Hub-and-Spoke task topology: global hub (`~/tasks/`) and repository-level spoke with the 3-file lifecycle (`active.md`, `future.md`, `completed.md`).
- **2026-07-14:** Introduced automated sprint archiving (`tmsweep.lua`).
- **2026-08-27:** Standardized semantic versioning, MIT licensing, and standalone distribution under Engenforge LLC.
