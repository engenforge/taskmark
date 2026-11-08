# Taskmark (`tm`)

**Taskmark** is a deterministic, multi-line, plain-text task specification (**SPEC-TASKMARK-04**) and CLI utility (`tm`) designed to work with any text editor and automated parsing tools.

It replaces the single-line constraints of formats like `todo.txt` while maintaining strict **CommonMark** compatibility, pure Markdown documents without YAML frontmatter friction, and predictable 4-space payload indentation rules.

---

## Table of Contents

- [Features](#features)
- [Specification Summary (SPEC-TASKMARK-04)](#specification-summary-spec-taskmark-04)
  - [Directory Architecture](#directory-architecture)
  - [Pure CommonMark Structure](#pure-commonmark-structure)
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
- [Provenance & Disambiguation](#provenance--disambiguation)
- [License](#license)

---

## Features

- **Pure CommonMark Compliant:** Standard markdown task lists (`- [ ]`, `- [x]`) read and written by a fixed, one-pass grammar that is itself a strict CommonMark subset — starting immediately at line 1 with standard headings, verified independently by a CommonMark reference parser in the test suite.
- **Deterministic & Machine-Readable:** Clear structure, explicit block separation, and a fixed 4-space context payload indent eliminate parsing ambiguity for automation tools, AI agents, and human workflows alike.
- **Auditable History:** Completed tasks retain a timestamp, plus a git commit hash when the task involved one (`> **Completed:** YYYY-MM-DD git:<sha>`).
- **Reverse-Chronological Archive:** Newly completed work is prepended to the top of `completed.tm.md` and grouped chronologically (`## YYYY-MM`), allowing developers and AI agents to inspect the latest accomplishments without scrolling.
- **Automated Task Lifecycle:** `tm sweep` moves individual completed tasks from the active sheet into `completed.tm.md`; `tm archive` ages out older sections into monthly archives.
- **Built-in Validator:** `tm validate` verifies strict spec compliance for task files and provides `--fix` auto-repair (including stripping the frontmatter block from pre-0.4 files).
- **Safe Concurrent Writes:** Every rewrite goes through a uniquely named temp file and an atomic rename, and mutating commands hold a short-lived `.tm.lock` on the task directory so concurrent runs (a human and an AI agent, say) wait for each other instead of losing updates.
- **Dependency-Free Runtime:** The tool that reads and writes your tasks is pure, portable Lua with no runtime dependency of any kind — no C compiler, no vendored library, nothing to build to install it.

---

## Specification Summary (SPEC-TASKMARK-04)

Read the full specification at [`doc/taskmark_spec.md`](doc/taskmark_spec.md).

### Directory Architecture

Taskmark task management is self-contained within `.tasks/` in each repository root:

```text
[Project Repository Root]/
└── .tasks/
    ├── active.tm.md       # Current sprint: tasks in active execution
    ├── future.tm.md       # Planned work backlog (by topic/tag)
    ├── completed.tm.md    # Reverse-chronological archive of completed work
    └── archive/           # Aged-out sections (moved automatically by `tm archive`)
        └── <YYYY>/
            └── <YYYY-MM>.tm.md
```

### Pure CommonMark Structure

In SPEC-TASKMARK-04, task files start immediately on line 1 with Markdown headings or top-level content. YAML frontmatter (`---`) is eliminated from `.tm.md` files; static project configuration is maintained externally in `.taskmarkrc`.

```markdown
# Current Sprint

Bootstrap work is blocked on the vendor contract; start with the socket path.

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

### Task & Context Indentation

- **Pending Task:** `^- \[ \] `
- **Completed Task:** `^- \[x\] ` (strictly lowercase `x`)
- **Multi-line Context Payload:** Aligned to list content with **exactly 4 spaces**.
- **Lazy-Continuation Separation:** Top-level prose following a task payload must be separated by at least one blank line (Rule V13).

### todo.txt-Derived Metadata

Optional conventions adapted from `todo.txt`, layered onto the existing task/payload grammar with no new parsing rules:

- **Priority:** single-letter flag right after the checkbox — `- [ ] (A) Fix the deployment pipeline`.
- **Project / context tags:** plain `+project` / `@context` words anywhere in the description — `+api @backend`.
- **Created / due dates:** labeled payload fields — `> **Created:** 2026-08-01`, `> **Due:** 2026-09-15`.

### Task Lifecycle

1. **Session Start:** Read `.tasks/active.tm.md` and pick the first pending task (`- [ ]`).
2. **Task Completion:**
   - Commit code changes to git, if any.
   - Mark task as `- [x]`.
   - Append `> **Completed:** YYYY-MM-DD` payload at 4-space indentation, adding
     `git:<short-sha>` whenever the task involved a commit.
3. **Sweep:** Run `tm sweep` to move completed tasks (each with its own payload) into `completed.tm.md` in reverse chronological order under a `## YYYY-MM` heading for the month of the sweep (or `## Sprint <id>` with `--sprint <id>`). Pending tasks, headings, and top-level prose stay put.
4. **Planning:** Nothing is ever promoted out of `future.tm.md` automatically; moving planned work into active work is always a deliberate edit.
5. **Archival:** Run `tm archive` periodically to move aged-out sections, newest first, to `.tasks/archive/<YYYY>/<YYYY-MM>.tm.md` — a section ages out once it is older than the 2 newest *and* its most recent `> **Completed:**` task is more than 14 days old.

### Configuration

All of the above paths are conventions, not hardcoded requirements. Configuration is read from two optional, flat `key: value` files — a local one for a single project and a global one for user-wide settings — resolved per key, highest priority first: an explicit command-line option, the local file, the global file, then the built-in default (see [`doc/taskmark_spec.md` §9](doc/taskmark_spec.md#9-configuration)):

- **Local** — `.taskmarkrc` in the directory you run `tm` from.
- **Global** — `$XDG_CONFIG_HOME/taskmark/config`, falling back to `~/.config/taskmark/config`.

```text
tasks_dir: .tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

`--tasks-dir` on the command line takes priority over both files; all three fall back to the built-in defaults shown above when unset. A project created before 0.4 that has only `doc/tasks/` (the old default) keeps resolving there until `.tasks/` exists or `tasks_dir` is configured.

---

## CLI Tool (`tm`)

The `tm` CLI provides utilities to manage and validate Taskmark documents.

### Subcommands

| Command | Description |
|---|---|
| `tm init` | Bootstrap taskmark folder and starter files (`active.tm.md`, `future.tm.md`, `completed.tm.md`). |
| `tm sweep [--sprint <id>]` | Move every completed task (with its payload) from `active.tm.md` to `completed.tm.md`, newest first, under `## YYYY-MM` (or `## Sprint <id>`). |
| `tm archive` | Move sections aged out of `completed.tm.md` into `archive/<YYYY>/<YYYY-MM>.tm.md`. |
| `tm validate [file...]` | Validate task file(s) against SPEC-TASKMARK-04 (defaults to the configured active file). |
| `tm indent [info]` | Prefix stdin with the four-space payload indent, optionally wrapped in a fenced code block. |
| `tm dedent [--fence]` | Remove the four-space payload indent from stdin. |
| `tm version` | Print current version string. |
| `tm help` | Display usage information. |

### Global & Command Options

- `--sprint <id>`: With `sweep`, bucket the swept tasks under `## Sprint <id>` instead of the current month.
- `--dry-run`: Preview changes without modifying any files. Applies to `sweep` and `archive`.
- `--tasks-dir <DIR>`: Path to task directory (defaults to `./.tasks`, or the `tasks_dir` set in [`.taskmarkrc`](#configuration)).
- `-h`, `--help`: Show command-specific help.

#### Examples

```bash
# Bootstrap taskmark directory and starter files
tm init

# Bootstrap in a custom directory
tm init --tasks-dir /path/to/repo/.tasks

# Validate the active task list
tm validate

# Validate a custom backlog file
tm validate ~/tasks/backlog.tm.md

# Validate multiple task files
tm validate .tasks/active.tm.md .tasks/future.tm.md

# Move completed tasks into the archive
tm sweep

# Preview a sweep into a named sprint section
tm sweep --sprint 2026-S4 --dry-run

# Close out a sprint: sweep its completed tasks under ## Sprint 2026-S4
tm sweep --sprint 2026-S4

# Archive aged sections in a specific directory
tm archive --tasks-dir /path/to/repo/.tasks

# Move a stack trace into a task's payload and back out again
tm indent < trace.txt >> .tasks/active.tm.md
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

Run the complete test suite (config reader, scanner, validator fixtures, sweep/archive, init, config, filters, and the CommonMark conformance oracle):

```bash
make test
```

Or run individual test runners directly:

```bash
# Config reader unit tests
lua tests/tmmeta_test.lua

# Line-scanner unit tests
lua tests/tmscan_test.lua

# Validator test runner
lua tests/test_runner.lua src/tmval.lua tests/fixtures

# Sweep/archive test runner
lua tests/tmsweep_test.lua

# Initialization test runner
lua tests/tminit_test.lua

# Configuration resolution test runner
lua tests/tmconfig_test.lua

# indent/dedent filter test runner
lua tests/tmfilter_test.lua

# I/O filesystem unit tests
lua tests/tmio_test.lua

# CommonMark conformance oracle (needs `make test`'s cmark.so build first)
lua tests/commonmark_test.lua
```

---

## Repository Structure

```text
.
├── AGENTS.md             # Coding agent instructions and project guidelines
├── CHANGELOG.md          # Project version history and specification timeline
├── LICENSE               # MIT License
├── Makefile              # Build, test, install, and packaging targets
├── VERSION               # Semantic version string
├── doc/
│   ├── taskmark_spec.md  # SPEC-TASKMARK-04 Specification document
│   ├── tm.1.scd          # scdoc source for tm(1) man page
│   └── tm.1              # Formatted roff man page
├── src/
│   ├── tm                # Executable CLI entrypoint / dispatcher
│   ├── tmmeta.lua        # Flat `key: value` configuration reader
│   ├── tmscan.lua        # Single-pass line scanner (headings, tasks, payloads)
│   ├── tminit.lua        # CLI runner for the init subcommand
│   ├── tmsweep.lua       # CLI runner for the sweep and archive subcommands
│   ├── tmsweep_core.lua  # Sweep, blank-line normalization, and archive-aging logic
│   ├── tmfilter.lua      # indent/dedent payload filters
│   ├── tmval.lua         # SPEC-TASKMARK-04 validation engine (rules V3-V13)
│   └── tmconfig.lua      # .taskmarkrc / global-config / --tasks-dir path resolution (§9)
├── tests/
│   ├── fixtures/         # Pass/fail Markdown test fixtures for the validator
│   ├── commonmark_test.lua # CommonMark conformance oracle (the only file that loads cmark.so)
│   ├── test_runner.lua   # Test runner for validator fixtures
│   ├── tmmeta_test.lua   # Unit tests for tmmeta
│   ├── tmscan_test.lua   # Unit tests for tmscan
│   ├── tminit_test.lua   # Unit & integration test suite for tminit
│   ├── tmsweep_test.lua  # Unit & integration test suite for tmsweep
│   ├── tmconfig_test.lua # Unit & integration test suite for tmconfig
│   ├── tmfilter_test.lua # Unit & round-trip test suite for tmfilter
│   └── tmio_test.lua     # Unit tests for tmio
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

## Provenance & Disambiguation

Taskmark was created by Jason Lenz (Engenforge LLC), with its initial specification (`SPEC-MDTASK-01`) and codebase originating on **June 30, 2026**.

**Disambiguation Note:** Engenforge Taskmark (`tm` / `.tm.md`) is an independent POSIX/CommonMark specification and dependency-free Lua CLI. It is completely unrelated to and unaffiliated with the Cursor IDE plugin and hosted service at `taskmark.dev`.

For a full historical record of releases and specification transitions, see [`CHANGELOG.md`](CHANGELOG.md).

---

## License

This project is licensed under the MIT License - see the [`LICENSE`](LICENSE) file for details.

Copyright (c) 2026 Engenforge LLC
