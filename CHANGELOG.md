# Changelog

All notable changes to Taskmark and the underlying task specification are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Changed
- **Transition to Pure CommonMark (SPEC-TASKMARK-04):**
  - **Removed Frontmatter from Task Files:** Taskmark files (`active.tm.md`, `future.tm.md`, `completed.tm.md`, `archive/<YYYY>/<YYYY-MM>.tm.md`) now start immediately on line 1 with standard Markdown headings. Frontmatter blocks (`---`) are eliminated, removing syntax friction and parsing ambiguities.
  - **Rule V13 (Lazy Continuation Enforcement):** Added Rule V13 requiring a blank line between a task line or its payload and any following top-level prose, so CommonMark lazy continuation cannot absorb the prose into the task's summary or payload. `tm validate --fix` inserts the blank line.
  - **Rule V14 (Leftover Frontmatter):** A pre-0.4 frontmatter block is reported once, as V14, instead of as misleading thematic-break/setext errors; `tm validate --fix` deletes it. An empty file is now a conforming document.
  - **Reverse-Chronological `completed.tm.md` and archives:** Swept tasks are bucketed under `## YYYY-MM` for the month of the sweep (or `## Sprint <id>` with `tm sweep --sprint <id>`), and both new sections and new tasks are prepended, so the latest work is at the top. Archive files are likewise kept newest first beneath their title.
  - **Removed `tm rotate`:** With no frontmatter there is no sprint state to rotate. `tm sweep --sprint <id>` covers the bucketing; spec §5.4 now describes sprint boundaries as a workflow convention.
  - **Archive retention:** `completed.tm.md` keeps its 2 newest sections (was 10), plus any section with a `Completed` task in the last 14 days — with monthly sections, the current and previous month.
  - **Scoped to Self-Contained Task Directories:** Removed global Hub-and-Spoke concepts from the normative specification, focusing the format strictly on repository-level `.tasks/` directories.
  - **Configuration Cleanup:** Removed unused hub configuration defaults (`hub_dir`, `inbox_file`, `dashboard_file`, `registry_file`) from `tmconfig.lua`.
  - **Validator Updates:** Dropped Rules V1/V2 (frontmatter required/well-formed).
  - **Code Cleanup:** `tmmeta.lua` is now only the configuration reader; frontmatter split/update helpers are gone.
- **Default task directory is now `.tasks/`** (was `doc/tasks/`), the recommended mount point for an orphan `tasks` branch worktree. A project with only `doc/tasks/` keeps resolving there when `tasks_dir` is not configured; run `git mv doc/tasks .tasks` (or set `tasks_dir: doc/tasks` in `.taskmarkrc`) to settle it.

### Fixed
- **Sweep into a `completed.tm.md` without a title:** no longer writes a duplicate section heading.
- **Atomic writes:** temp files are uniquely named per write, a short write or failed flush never replaces the original, and `tm validate --fix` now uses the same writer (preserving CRLF documents).
- **Concurrent runs:** `sweep`, `archive`, and `validate --fix` hold a short-lived `.tm.lock` on the task directory so concurrent runs wait instead of losing updates.

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
