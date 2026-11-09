# Agent instructions

Guidance for any AI agent working on Taskmark. Read this before changing the specification, implementation, documentation, or test suite.

## Commands

- Run full test suite: `make test` (or `make check`)
- Run individual test runners:
  - Line-scanner unit tests: `lua tests/tmscan_test.lua`
  - Config reader unit tests: `lua tests/tmmeta_test.lua`
  - Validator tests: `lua tests/test_runner.lua src/tmval.lua tests/fixtures`
  - Sweep/archive tests: `lua tests/tmsweep_test.lua`
  - Init tests: `lua tests/tminit_test.lua`
  - Sync tests: `lua tests/tmsync_test.lua`
  - Release tooling tests: `lua tests/release_test.lua`
  - Mutation tests (list/add/done/move): `lua tests/tmmutate_test.lua`
  - Config resolution tests: `lua tests/tmconfig_test.lua`
  - Filter tests: `lua tests/tmfilter_test.lua`
  - I/O filesystem unit tests: `lua tests/tmio_test.lua`
  - CommonMark conformance oracle: `lua tests/commonmark_test.lua` (requires `make build/cmark.so`)
- Check man page matches scdoc source: `make man-check`
- Regenerate man page from scdoc source: `make man` (requires `scdoc >= 1.11.5`)
- Reproducible source tarball in `build/dist/`: `make dist`
- Reproducible installed-image tarball in `build/dist/`: `make dist-bin`
- Prepare a release (maintainer only; never without being asked): `make pre-release VERSION=X.Y.Z` -- bumps `VERSION` and dates the changelog; the maintainer reviews, commits, and tags

## Boundaries

- **Always:** run `make test` before committing; ensure all tests pass cleanly.
- **Always:** follow TDD protocol per `CONTEXT.md` (verify baseline, test-first, confirm failure, minimal implementation, verify, refactor, commit).
- **Never:** push or tag without being asked; commit scratch notes or chat transcripts; add files specific to one AI tool (this file is the single, tool-neutral source of agent guidance).

## Task tracking

- This project tracks its own work with Taskmark. Current tasks are in `.tasks/active.tm.md`, planned work in `.tasks/future.tm.md`, and finished work in `.tasks/completed.tm.md` (newest first).
- `.tasks/` is a git worktree of the orphan `tasks` branch and is ignored on `main`, so repository-wide searches skip it: read or search those paths directly.
- Prefer the CLI to hand-editing: `tm list` for a compact view, `tm done <handle> --git` to complete a task, `tm add`/`tm move` to add or promote one. Commit task changes with `tm sync`, never as part of a code commit.

## Sources of truth

1. **`doc/taskmark_spec.md`** is the normative authority for the SPEC-TASKMARK-04 specification.
2. The validator (`src/tmval.lua`) and line scanner (`src/tmscan.lua`) must enforce what the specification defines.
3. Informative documents (`README.md`, `doc/tm.1.scd`, etc.) follow the specification.

## External Path Exceptions

- `~/tasks/`
- `~/tasks`

## Repository notes

- `make dist` and `make dist-bin` build only from the committed `HEAD`; uncommitted and untracked files are never included, so commit first. Each removes earlier commits' artifacts from `build/dist/` before building.
- Man pages are written in scdoc (`doc/tm.1.scd`); the generated roff (`doc/tm.1`) is committed to the repository. Regenerate using `make man` and commit both.
