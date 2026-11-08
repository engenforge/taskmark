---
project: taskmark
status: Active
sprint: 2026-S3
date: 2026-11-08
---

# Current Sprint

- [x] (A) +io @lua Runtime hardening: collision-safe atomic writes in `src/tmio.lua`
    > **Context:** `tmio.write_file_atomic` currently uses a static `path .. ".tmp"` filename. If multiple processes, sub-agents, or test runs write concurrently, they can collide or clobber each other's temporary files.
    > **Requirements:** Replace static `.tmp` suffix with a unique temporary file path incorporating PID and timestamp/random token (or `os.tmpname()` within target directory to ensure atomic cross-link rename on the same filesystem). Preserve document newline detection and atomic rename behavior.
    > **Files:** `src/tmio.lua`, `tests/tmsweep_test.lua`.
    > **Verify:** `make test` passes 100%; unit test confirms concurrent/repeated atomic writes do not collide.
    > **Completed:** 2026-11-08

- [ ] (A) +spec @lua Spec & grammar evolution: transition to pure CommonMark (SPEC-TASKMARK-04)
    > **Context:** YAML frontmatter blocks (`---`) in `.tm.md` files introduce syntax friction for AI agents and human editors, require an arbitrary `updated:` date field that frequently becomes stale, and complicate the parser stack. Moving to pure CommonMark eliminates frontmatter from task files, simplifies `tmscan.lua`, and drops frontmatter maintenance from `tmval.lua` and `tmsweep.lua`.
    > **Requirements:**
    > - Remove frontmatter requirements from task documents; task files start immediately with `#` or `##` CommonMark headings.
    > - Retain `src/tmmeta.lua` solely for parsing `.taskmarkrc` static workspace configuration.
    > - Simplify `src/tmscan.lua` to scan from line 1 without skipping frontmatter headers.
    > - Update `src/tmval.lua` to validate pure CommonMark task documents without requiring frontmatter.
    > - Incorporate Rule V13 lazy-continuation boundary enforcement (prose must not directly follow a payload without a blank line).
    > - Update `src/tmsweep.lua` / `src/tmsweep_core.lua` to append completed tasks under chronological headings (`## YYYY-MM`) without requiring or mutating frontmatter dates, settling archive tail trailing blank-line normalization.
    > - Update `doc/taskmark_spec.md` to `SPEC-TASKMARK-04`, and update fixture corpus and tests.
    > **Verify:** `make test` and CommonMark oracle pass cleanly; all fixtures updated and conforming.

- [ ] (A) +cli @lua AI & CLI ergonomics: atomic task mutations and compact listings
    > **Context:** AI coding agents and human developers frequently encounter formatting or line-drift errors when manually splicing task lines and completed blocks into Markdown files. A CLI mutation suite prevents formatting errors and saves AI context tokens.
    > **Requirements:**
    > - Implement `tm done <pattern-or-id> [--git HEAD]`: locates the target pending task in `active.tm.md`, marks it `- [x]`, resolves completion date and current git SHA, appends compliant 4-space `> **Completed:**` payload, and saves atomically.
    > - Implement `tm list [--pending|--all]`: uses `tmscan.lua` to stream compact single-line task summaries without payload blocks to preserve LLM token context.
    > - Implement `tm add <task-text> [--section <name>]`: safely appends a task under the target heading.
    > - Merge task movement capabilities: support `tm move <pattern> --from <file> --to <file>` (non-destructive copy-then-delete) to promote tasks from `future.tm.md` to `active.tm.md`.
    > **Files:** `src/tm`, `src/tmscan.lua`, `tests/tmmutation_test.lua` (or similar), man pages.
    > **Verify:** End-to-end CLI unit and integration tests; `tm validate` passes on mutated files.

- [ ] (B) +git @workflow Orphan Git branch topology and worktree integration
    > **Context:** Storing task tracking files directly in the main codebase branch introduces commit noise and pull-request churn. Mounting an orphan `tasks` branch into `.tasks/` via `git worktree add` isolates task history from primary code history.
    > **Requirements:**
    > - Implement `~` path expansion in `src/tmconfig.lua` so hub and tasks paths resolve reliably via `$HOME`.
    > - Add `tm init --orphan [branch]` command (or document worktree bootstrap) to automate initializing an orphan branch, ignoring `.tasks` on `main`, configuring `tasks_dir: .tasks` in `.taskmarkrc`, and mounting `.tasks` as a sub-worktree.
    > - Document cross-branch `git: <sha>` commit references in `doc/taskmark_spec.md`, noting how references resolve against the shared Git object store.
    > - Provide optional `tm sync` / auto-commit helper to commit changes in `.tasks/` to the orphan branch.
    > **Verify:** Clean worktree initialization, end-to-end task mutations on mounted worktree, and validation that `git status` on `main` ignores `.tasks/`.
