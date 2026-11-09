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

1. **Session Start:** Read `.tasks/active.tm.md` or inspect tasks compactly with `tm list`.
2. **Task Creation:** Add new work with `tm add "Task description" -p A` (directly under the first heading, or `--section <name>`).
3. **Task Promotion:** Promote planned items from backlog to active with `tm move <handle>` (defaults from `future.tm.md` to `active.tm.md`).
4. **Task Completion:**
   - Commit code changes to git, if any.
   - Run `tm done <handle> --git` to atomically mark the task completed (`- [x]`), record today's ISO date, and append `git:<sha>` (or run without `--git` for non-coding tasks).
5. **Sweep:** Run `tm sweep` to move completed tasks (each with its own payload) into `completed.tm.md` in strict reverse chronological order under a `## YYYY-MM` heading for the month of the sweep (or `## Sprint <id>` with `--sprint <id>`). Pending tasks, headings, and top-level prose stay put.
6. **Archival:** Run `tm archive` periodically to move aged-out sections, newest first, to `.tasks/archive/<YYYY>/<YYYY-MM>.tm.md` — a section ages out once it is older than the 2 newest *and* its most recent `> **Completed:**` task is more than 14 days old.

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

### Orphan Branch Topology & Worktrees

To decouple task tracking history from primary code history while keeping task files strictly local to the repository, Taskmark supports an orphan branch topology:

1. **Isolation:** Task history lives on an independent branch (conventionally `tasks`) with no shared commit history with `main`.
2. **Worktree Mounting:** The orphan branch is mounted into `.tasks/` via a git worktree. `tm init --orphan` creates it, or — in a fresh clone of a project that already has one — mounts the existing remote branch, so collaborators share one task history.
3. **Ignored in Code:** `.gitignore` on `main` ignores `/.tasks/`, eliminating task commit churn and pull-request noise on code branches.
4. **Cross-Branch Auditability:** Completed tasks stamp the code commit SHA (`git:<sha>`), linking the orphan task archive directly to the codebase commit.
5. **Tooling:** Automated by `tm init --orphan [branch]` (run from the repository root) and synchronized with `tm sync`. Git hooks run normally for both.
6. **Search tools:** `ripgrep`-based tools, including many AI agents, skip ignored `.tasks/` in repository-wide searches but still read it by path. Name `.tasks/active.tm.md` in your agent instructions, or add a `.ignore` file containing `!/.tasks/` to include it in searches (see spec §10.2).

---

## CLI Tool (`tm`)

The `tm` CLI provides utilities to manage and validate Taskmark documents.

### Subcommands

| Command | Description |
|---|---|
| `tm init [--orphan [BRANCH]]` | Bootstrap taskmark folder and starter files (with `--orphan`, initializes an isolated orphan Git branch mounted as a worktree). |
| `tm sync [-m MSG] [-p]` | Commit modified taskmark files in the tasks directory to the orphan branch (`-p` pushes to remote). |
| `tm list [--pending\|--all]` | One line per task — its handle and summary (`[f4a1] (A) Task text`), no payloads. Handles are the shortest unique hash prefix of at least 4 hex digits. |
| `tm add <text> [-p PRI] [--section S]` | Add a task to an existing file, under the first heading or the named section. |
| `tm done <handle\|pattern> [--git [REV]]` | Mark a pending task completed, stamping the local date and optionally `git:<sha>` of REV (default `HEAD`). |
| `tm move <handle\|pattern> [--from F] [--to T] [--section S]` | Move a task between files or sections (default: `future.tm.md` to `active.tm.md`); destination written first. |
| `tm sweep [--sprint <id>]` | Move every completed task (with its payload) from `active.tm.md` to `completed.tm.md`, newest first, under `## YYYY-MM` (or `## Sprint <id>`). |
| `tm archive` | Move sections aged out of `completed.tm.md` into `archive/<YYYY>/<YYYY-MM>.tm.md`. |
| `tm validate [file...]` | Validate task file(s) against SPEC-TASKMARK-04 (defaults to the configured active file). |
| `tm indent [info]` | Prefix stdin with the four-space payload indent, optionally wrapped in a fenced code block. |
| `tm dedent [--fence]` | Remove the four-space payload indent from stdin. |
| `tm version` | Print current version string. |
| `tm help` | Display usage information. |

### Global & Command Options

- `--pending`: With `list`, stream only pending tasks (default).
- `--all`: With `list`, stream both pending and completed tasks.
- `-p, --priority <PRI>`: With `add`, assign priority `(A)`-`(Z)`.
- `--section <SEC>`: With `add` or `move`, specify target heading.
- `--git [REV]`: With `done`, record git commit SHA (`git:<sha>`, defaulting to `HEAD`).
- `--from <FILE>`: With `move`, source file (default: `future.tm.md`).
- `--to <FILE>`: With `move`, destination file (default: `active.tm.md`).
- `--sprint <id>`: With `sweep`, bucket the swept tasks under `## Sprint <id>` instead of the current month.
- `--dry-run`: Preview changes without modifying any files. Applies to `sweep` and `archive`.
- `--orphan [BRANCH]`: With `init`, initialize an isolated orphan Git branch (default: `tasks`), add the directory to `.gitignore` (and record a non-default directory in `.taskmarkrc`), and mount it as a worktree.
- `-m, --message <MSG>`: With `sync`, commit message for the orphan branch commit.
- `-p, --push`: With `sync`, push after committing; the first push sets the upstream (to `origin`, or the only remote).
- `--tasks-dir <DIR>`: Path to task directory (defaults to `./.tasks`, or the `tasks_dir` set in [`.taskmarkrc`](#configuration)).
- `-h`, `--help`: Show command-specific help.

#### Examples

```bash
# Bootstrap taskmark directory with an isolated orphan branch worktree
tm init --orphan

# Synchronize task changes to the orphan branch
tm sync -m "tasks: update sprint backlog"

# List pending tasks, one line each, with their handles
tm list

# Add a high-priority task to the active sprint
tm add "Implement socket timeout handling" -p A

# Mark a task completed with the current commit's SHA (or a named commit)
tm done f4a1 --git
tm done "socket timeout" --git=abc1234

# Promote task from backlog (future.tm.md) to active sprint (active.tm.md)
tm move 8b12

# Validate the active task list
tm validate

# Move completed tasks into the archive in reverse chronological order
tm sweep

# Preview a sweep into a named sprint section
tm sweep --sprint 2026-S4 --dry-run

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
- *(Optional)* **Git**, only for the features built on it (`tm init --orphan`, `tm sync`, `tm done --git`) and for maintainers (`make dist`, `make dist-bin`, `make pre-release`). `make`, `make test`, and `make install` work without it; tests that need git are skipped and reported.

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

`make dist` (source) and `make dist-bin` (installed files) build from the committed `HEAD`, producing byte-identical tarballs listed in `build/dist/SHA256SUMS`. Each first removes anything in `build/dist/` that is not one of the current commit's two tarballs, so after `make dist dist-bin` the directory and `SHA256SUMS` hold exactly that release pair. GNU tar and xz are required.

### Cutting a Release

`VERSION` is the only place the version number lives, and the `[Unreleased]` section of `CHANGELOG.md` collects changes as they land. To release:

```bash
make pre-release VERSION=0.4.0   # checks and tests, then bumps VERSION and dates the changelog
git diff                         # review the two edited files
git commit -am 'Release 0.4.0'
git tag -s v0.4.0 -m 'Taskmark v0.4.0'
make dist dist-bin               # build/dist/taskmark-0.4.0{,-noarch}.tar.xz and SHA256SUMS
git push <remote> main v0.4.0
```

`make pre-release` refuses to run on a dirty tree, for a version that is not newer than `VERSION`, for an existing tag, or with an empty `[Unreleased]` section, and it runs `make test` (which includes `make man-check`) before changing anything. It only edits `VERSION` and `CHANGELOG.md`: committing, tagging, and signing are left to you, after review (`git checkout -- VERSION CHANGELOG.md` abandons it). `make dist` refuses to build a tagged commit whose `VERSION` does not match the tag.

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
├── VERSION               # Semantic version string (the only copy; see Cutting a Release)
├── doc/
│   ├── taskmark_spec.md  # SPEC-TASKMARK-04 Specification document
│   ├── tm.1.scd          # scdoc source for tm(1) man page
│   └── tm.1              # Formatted roff man page
├── scripts/
│   └── release.lua       # Steps behind `make pre-release`
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
