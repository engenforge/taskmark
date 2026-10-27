# Taskmark (`tm`)

**Taskmark** is a deterministic, multi-line, plain-text task specification (**SPEC-TASKMARK-03**) and CLI utility (`tm`) designed to work with any text editor and automated parsing tools.

It replaces the single-line constraints of formats like `todo.txt` while maintaining strict **CommonMark** compatibility, predictable indentation rules, and a clean hub-and-spoke project topology.

---

## Table of Contents

- [Features](#features)
- [Specification Summary (SPEC-TASKMARK-03)](#specification-summary-spec-taskmark-03)
  - [Directory Architecture](#directory-architecture)
  - [Frontmatter Schema](#frontmatter-schema)
  - [Task & Context Indentation](#task--context-indentation)
  - [todo.txt-Derived Metadata](#todotxt-derived-metadata)
  - [Task Lifecycle](#task-lifecycle)
  - [Configuration](#configuration)
- [CLI Tool (`tm`)](#cli-tool-tm)
  - [Subcommands](#subcommands)
  - [Global & Command Options](#global--command-options)
- [Installation](#installation)
- [Running Tests](#running-tests)
- [Repository Structure](#repository-structure)
- [Repositories & Mirrors](#repositories--mirrors)
- [License](#license)

---

## Features

- **CommonMark Compliant:** Standard markdown task lists (`- [ ]`, `- [x]`) read and written by a fixed, one-pass grammar that is itself a strict CommonMark subset — checked independently by a CommonMark reference parser in the test suite, not merely asserted.
- **Deterministic & Machine-Readable:** Clear structure, explicit flat-frontmatter boundaries, and a fixed 4-space context payload indent eliminate parsing ambiguity for automation tools and human workflows alike.
- **Auditable History:** Completed tasks retain a timestamp, plus a git commit hash when the task involved one (`> **Completed:** YYYY-MM-DD git:<sha>`).
- **Automated Task Lifecycle:** `tm sweep` moves individual completed tasks from the active sheet to the archive; `tm rotate` does that and bumps the sprint; `tm archive` ages out older sections into monthly archives.
- **Built-in Validator:** `tm validate` verifies strict spec compliance for task files.
- **Dependency-Free Runtime:** The tool that reads and writes your tasks is pure, portable Lua with no runtime dependency of any kind — no C compiler, no vendored library, nothing to build to install it.

---

## Specification Summary (SPEC-TASKMARK-03)

Read the full specification at [`doc/taskmark_spec.md`](doc/taskmark_spec.md).

### Directory Architecture

Taskmark separates global project indexing from repository-level execution:

- **Hub (Global Workspace):** `~/tasks/` containing global indexes and cross-repo status.
- **Spoke (Local Repository):** Managed inside `doc/tasks/` in each repository root:

```text
[Project Repository Root]/
└── doc/
    └── tasks/
        ├── active.tm.md       # Current sprint: tasks in active execution
        ├── future.tm.md       # Planned work backlog (by topic/tag)
        ├── completed.tm.md    # Append-only archive of completed sprints
        └── archive/           # Aged-out sections (moved automatically by `tm archive`)
            └── <YYYY>/
                └── <YYYY-MM>.tm.md
```

### Frontmatter Schema

Each task document begins with a flat `key: value` frontmatter block, delimited by `---`:

```markdown
---
project: taskmark
status: Active
sprint: 2026-S3
date: 2026-08-27
---
```

- `project` — repository slug
- `status` — `Active` | `Planned` | `Archive`
- `sprint` — sprint identifier (`active.tm.md` only)
- `date` — ISO date of last structural update

### Task & Context Indentation

- **Pending Task:** `^- \[ \] `
- **Completed Task:** `^- \[x\] ` (strictly lowercase `x`)
- **Multi-line Context Payload:** Aligned to list content with **exactly 4 spaces**.

```markdown
# Current Sprint

- [ ] Implement socket timeout handling
    > **Context:** Prevent hanging instances from dropped peers.
    > **Notes:** Look at `src/net.c` near line 42. Inject setsockopt.

    ```c
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    ```

- [x] Add configuration file parser
    > **Completed:** 2026-08-27 git:9bfa798
```

### todo.txt-Derived Metadata

Optional conventions adapted from `todo.txt`, layered onto the existing task/payload grammar with no new parsing rules:

- **Priority:** single-letter flag right after the checkbox — `- [ ] (A) Fix the deployment pipeline`.
- **Project / context tags:** plain `+project` / `@context` words anywhere in the description — `+api @backend`.
- **Created / due dates:** labeled payload fields — `> **Created:** 2026-08-01`, `> **Due:** 2026-09-15`.

### Task Lifecycle

1. **Session Start:** Read `doc/tasks/active.tm.md` and pick the first pending task (`- [ ]`).
2. **Task Completion:**
   - Commit code changes to git, if any.
   - Mark task as `- [x]`.
   - Append `> **Completed:** YYYY-MM-DD` payload at 4-space indentation, adding
     `git:<short-sha>` whenever the task involved a commit.
3. **Sweep:** Run `tm sweep` to move completed tasks (each with its own payload) into `completed.tm.md`. Pending tasks, headings, and top-level prose stay put, even once every task beneath them is done.
4. **Rotation:** Run `tm rotate --sprint <new-id>` at a sprint boundary — a sweep, plus a new `sprint`/`date` stamp on `active.tm.md` and a `date` stamp on `completed.tm.md`. Nothing is ever promoted out of `future.tm.md` automatically; moving planned work into the active sprint is always a deliberate edit.
5. **Archival:** Run `tm archive` periodically to move aged-out sections to `doc/tasks/archive/<YYYY>/<YYYY-MM>.tm.md` — a section ages out once it is older than the 10 newest *and* its most recent `> **Completed:**` task is more than 14 days old.

### Configuration

All of the above paths are conventions, not hardcoded requirements. Configuration is read from two optional, flat `key: value` files — a local one for a single project and a global one for user-wide settings like the hub location — resolved per key, highest priority first: an explicit command-line option, the local file, the global file, then the built-in default (see [`doc/taskmark_spec.md` §10](doc/taskmark_spec.md#10-configuration)):

- **Local** — `.taskmarkrc` in the directory you run `tm` from.
- **Global** — `$XDG_CONFIG_HOME/taskmark/config`, falling back to `~/.config/taskmark/config`.

```text
tasks_dir: doc/tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

`--tasks-dir` on the command line takes priority over both files; all three fall back to the built-in defaults shown above when unset.

---

## CLI Tool (`tm`)

The `tm` CLI provides utilities to manage and validate Taskmark documents.

### Subcommands

| Command | Description |
|---|---|
| `tm init` | Bootstrap taskmark folder and starter files (`active.tm.md`, `future.tm.md`, `completed.tm.md`). |
| `tm sweep` | Move every completed task (with its payload) from `active.tm.md` to `completed.tm.md`. |
| `tm rotate --sprint <id>` | A sweep, then bump `active.tm.md`'s `sprint`/`date` and `completed.tm.md`'s `date`. |
| `tm archive` | Move sections aged out of `completed.tm.md` into `archive/<YYYY>/<YYYY-MM>.tm.md`. |
| `tm validate [file...]` | Validate task file(s) against SPEC-TASKMARK-03 (defaults to the configured active file). |
| `tm indent [info]` | Prefix stdin with the four-space payload indent, optionally wrapped in a fenced code block. |
| `tm dedent [--fence]` | Remove the four-space payload indent from stdin. |
| `tm version` | Print current version string. |
| `tm help` | Display usage information. |

### Global & Command Options

- `--sprint <VALUE>`: New sprint identifier to stamp on `active.tm.md`. Required with `rotate`.
- `--dry-run`: Preview changes without modifying any files. Applies to `sweep`, `rotate`, and `archive`.
- `--tasks-dir <DIR>`: Path to task directory (defaults to `./doc/tasks`, or the `tasks_dir` set in [`.taskmarkrc`](#configuration)).
- `-h`, `--help`: Show command-specific help.

#### Examples

```bash
# Bootstrap taskmark directory and starter files
tm init

# Bootstrap in a custom directory
tm init --tasks-dir /path/to/repo/doc/tasks

# Validate the active task list
tm validate

# Validate a custom backlog file
tm validate ~/tasks/backlog.tm.md

# Validate multiple task files
tm validate doc/tasks/active.tm.md doc/tasks/future.tm.md

# Move completed tasks into the archive
tm sweep

# Preview a sprint rotation
tm rotate --sprint 2026-S4 --dry-run

# Rotate into a new sprint
tm rotate --sprint 2026-S4

# Archive aged sections in a specific directory
tm archive --tasks-dir /path/to/repo/doc/tasks

# Move a stack trace into a task's payload and back out again
tm indent < trace.txt >> doc/tasks/active.tm.md
tm dedent --fence < payload-excerpt.txt > trace.txt
```

---

## Installation

### Prerequisites

- **Lua** (5.1, 5.2, 5.3, 5.4, or LuaJIT) — that's all `tm` itself needs.
- Standard Unix utilities (`make`, `install`, `mkdir`)
- *(Optional)* A **C compiler** (`gcc` or `clang`) and Lua development headers, only to run the test suite's CommonMark conformance oracle (`make test`) — never to install.
- *(Optional)* `scdoc` (>= 1.11.5) to rebuild the `tm(1)` man page from source (`make man`)

### Install via Makefile

```bash
# Install to /usr/local (default)
sudo make install

# Or install to custom prefix (e.g. ~/.local)
make install PREFIX=$HOME/.local
```

### Build Release Tarballs

Build reproducible release tarballs in `build/dist/`:

```bash
# Build reproducible source tarball (taskmark-<ver>.tar.xz):
make dist

# Build reproducible architecture-independent installed package (taskmark-<ver>-noarch.tar.xz):
make dist-bin
```

`make dist` (source) and `make dist-bin` (installed files) build from the committed `HEAD`, producing byte-identical tarballs listed in `build/dist/SHA256SUMS`. GNU tar and xz are required.

### Uninstall

```bash
sudo make uninstall [PREFIX=/usr/local]
```

---

## Running Tests

Run the complete test suite (metadata, scanner, validator fixtures, sweep/rotate/archive, init, config, filters, and the CommonMark conformance oracle):

```bash
make test
```

Or run individual test runners directly:

```bash
# Frontmatter/config reader unit tests
lua tests/tmmeta_test.lua

# Line-scanner unit tests
lua tests/tmscan_test.lua

# Validator test runner
lua tests/test_runner.lua src/tmval.lua tests/fixtures

# Sweep/rotate/archive test runner
lua tests/tmsweep_test.lua

# Initialization test runner
lua tests/tminit_test.lua

# Configuration resolution test runner
lua tests/tmconfig_test.lua

# indent/dedent filter test runner
lua tests/tmfilter_test.lua

# CommonMark conformance oracle (needs `make test`'s cmark.so build first)
lua tests/commonmark_test.lua
```

---

## Repository Structure

```text
.
├── AGENTS.md             # Coding agent instructions and project guidelines
├── LICENSE               # MIT License
├── Makefile              # Build, test, install, and packaging targets
├── VERSION               # Semantic version string
├── doc/
│   ├── taskmark_spec.md  # SPEC-TASKMARK-03 Specification document
│   ├── tm.1.scd          # scdoc source for tm(1) man page
│   └── tm.1              # Formatted roff man page
├── src/
│   ├── tm                # Executable CLI entrypoint / dispatcher
│   ├── tmmeta.lua        # Flat `key: value` frontmatter/config reader & writer
│   ├── tmscan.lua        # Single-pass line scanner (headings, tasks, payloads)
│   ├── tminit.lua        # CLI runner for the init subcommand
│   ├── tmsweep.lua       # CLI runner for the sweep, rotate, and archive subcommands
│   ├── tmsweep_core.lua  # Sweep, blank-line normalization, and archive-aging logic
│   ├── tmfilter.lua      # indent/dedent payload filters
│   ├── tmval.lua         # SPEC-TASKMARK-03 validation engine (rules V1-V12)
│   └── tmconfig.lua      # .taskmarkrc / global-config / --tasks-dir path resolution (§10)
├── tests/
│   ├── fixtures/         # Pass/fail Markdown test fixtures for the validator
│   ├── commonmark_test.lua # CommonMark conformance oracle (the only file that loads cmark.so)
│   ├── test_runner.lua   # Test runner for validator fixtures
│   ├── tmmeta_test.lua   # Unit tests for tmmeta
│   ├── tmscan_test.lua   # Unit tests for tmscan
│   ├── tminit_test.lua   # Unit & integration test suite for tminit
│   ├── tmsweep_test.lua  # Unit & integration test suite for tmsweep
│   ├── tmconfig_test.lua # Unit & integration test suite for tmconfig
│   └── tmfilter_test.lua # Unit & round-trip test suite for tmfilter
└── vendor/
    └── cmark/            # Vendored libcmark & cmark-lua binding (test-only; never
                           # built, installed, or loaded at runtime)
```

---

## Repositories & Mirrors

Project website: https://git.engenforge.com/taskmark

The primary git repository is hosted on Engenforge infrastructure and mirrored to GitLab and GitHub:
- Primary: `https://git.engenforge.com/taskmark.git`
- Secondary: `https://gitlab.com/engenforge/taskmark.git`
- Secondary: `https://github.com/engenforge/taskmark.git`

Release tarballs (`taskmark-<ver>.tar.xz` source, `taskmark-<ver>-noarch.tar.xz` architecture-independent package, and `SHA256SUMS`) are published for each version (`<ver>`, tagged as `v<ver>`):
- Primary: `https://get.engenforge.com/taskmark/<ver>/<filename>`
- Secondary: `https://gitlab.com/engenforge/taskmark/-/releases/v<ver>/downloads/<filename>`
- Secondary: `https://github.com/engenforge/taskmark/releases/download/v<ver>/<filename>`

---

## License

This project is licensed under the MIT License - see the [`LICENSE`](LICENSE) file for details.

Copyright (c) 2026 Engenforge LLC
