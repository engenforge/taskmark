# Current Sprint

- [x] (A) +io @lua Runtime hardening: collision-safe atomic writes in `src/tmio.lua`
    > **Context:** `tmio.write_file_atomic` currently uses a static `path .. ".tmp"` filename. If multiple processes, sub-agents, or test runs write concurrently, they can collide or clobber each other's temporary files.
    > **Requirements:** Replace static `.tmp` suffix with a unique temporary file path incorporating PID and timestamp/random token (or `os.tmpname()` within target directory to ensure atomic cross-link rename on the same filesystem). Preserve document newline detection and atomic rename behavior.
    > **Files:** `src/tmio.lua`, `tests/tmio_test.lua`.
    > **Verify:** `make test` passes 100%; unit test confirms concurrent/repeated atomic writes do not collide.
    > **Completed:** 2026-11-08 git:e5c61e7

- [x] (A) +spec @lua Spec & grammar evolution: transition to pure CommonMark (SPEC-TASKMARK-04)
    > **Context:** YAML frontmatter blocks (`---`) in `.tm.md` files introduce syntax friction for AI agents and human editors, require an arbitrary `updated:` date field that frequently becomes stale, and complicate the parser stack. Moving to pure CommonMark eliminates frontmatter from task files, simplifies `tmscan.lua`, and drops frontmatter maintenance from `tmval.lua` and `tmsweep.lua`. Furthermore, removing the unimplemented "Hub and Spoke" architecture scopes the specification cleanly to self-contained Taskmark directories.
    > **Requirements:**
    > - Remove frontmatter requirements from task documents; task files start immediately with `#` or `##` CommonMark headings.
    > - Retain `src/tmmeta.lua` solely for parsing `.taskmarkrc` static workspace configuration.
    > - Simplify `src/tmscan.lua` to scan from line 1 without skipping frontmatter headers.
    > - Update `src/tmval.lua` to validate pure CommonMark task documents without requiring frontmatter.
    > - Incorporate Rule V13 lazy-continuation boundary enforcement (prose must not directly follow a payload without a blank line).
    > - Update `src/tmsweep.lua` / `src/tmsweep_core.lua` to append completed tasks under chronological headings (`## YYYY-MM`) without requiring or mutating frontmatter dates, settling archive tail trailing blank-line normalization.
    > - Scope the specification strictly to self-contained Taskmark directories: remove normative global Hub concepts from `doc/taskmark_spec.md`.
    > - Simplify `src/tmconfig.lua`: remove unused hub configuration defaults (`.tasks` default implemented in main).
    > - Update `doc/taskmark_spec.md` to `SPEC-TASKMARK-04`, and update fixture corpus and tests.
    > **Verify:** `make test` and CommonMark oracle pass cleanly; all fixtures updated and conforming.
    > **Completed:** 2026-11-08 git:017307a

- [x] (A) +cli @lua AI & CLI ergonomics: atomic task mutations, compact listings, and ephemeral hashes
    > **Context:** AI coding agents and human developers frequently encounter formatting or line-drift errors when manually splicing task lines and completed blocks into Markdown files. A CLI mutation suite prevents formatting errors and saves AI context tokens. Runtime ephemeral hashing provides exact CLI handles without polluting Markdown files with sequential numbers or ID counters.
    > **Requirements:**
    > - Implement runtime ephemeral task hashing in `tm` / `tmscan.lua`: compute a deterministic 4-character hex hash (e.g. DJB2/FNV-1a) of the normalized task summary on the fly. Normalization MUST exclude the checkbox state so a task keeps its handle across `tm done`. Four hex digits collide often enough (~26% for some pair among 200 tasks) that an ambiguous handle must be rejected with the candidates listed, and a longer prefix of the full hash accepted, git-style.
    > - Implement `tm list [--pending|--all]`: uses `tmscan.lua` to stream compact single-line task summaries with 4-char hash prefixes (e.g. `[f4a1] (A) Task text`) without payload blocks to preserve LLM token context.
    > - Implement `tm done <hash-or-pattern> [--git HEAD]`: locates the target pending task in `active.tm.md` by 4-char hash or substring match, marks it `- [x]`, resolves completion date and current git SHA, appends compliant 4-space `> **Completed:**` payload, and saves atomically.
    > - Implement `tm move <hash-or-pattern> --from <file> --to <file>`: non-destructive copy-then-delete task promotion from `future.tm.md` to `active.tm.md` (write the destination first, as sweep does, and hold `tmio.with_lock`).
    > - Implement `tm add <task-text> [--section <name>]`: safely appends a task under the target heading.
    > - Ensure `completed.tm.md` is maintained in strict reverse chronological order: the most recently completed sections (e.g. `## YYYY-MM`) and individual completed tasks are placed at the top of the file/section, allowing humans and AI agents to inspect the latest work immediately without scrolling to the end of a long file.
    > - Preserve inverted traceability: tasks link to git commits via the spec's `git:<sha>` form in the `Completed` field, with zero task numbering syntax in Markdown files.
    > **Files:** `src/tm`, `src/tmscan.lua`, `src/tmsweep.lua`, `tests/tmmutation_test.lua` (or similar), man pages.
    > **Verify:** End-to-end CLI unit and integration tests; `tm validate` passes on mutated files; verify reverse-chronological order in `completed.tm.md`.
    > **Completed:** 2026-11-08 git:368c79e

- [x] (B) +git @workflow Orphan Git branch topology and worktree integration
    > **Context:** Storing task tracking files directly in the main codebase branch introduces commit noise and pull-request churn. Mounting an orphan `tasks` branch into `.tasks/` via `git worktree add` isolates task history from primary code history.
    > **Requirements:**
    > - Add `tm init --orphan [branch]` command to automate initializing an orphan branch, ignoring `.tasks` on `main`, configuring `tasks_dir: .tasks` in `.taskmarkrc`, and mounting `.tasks` as a sub-worktree.
    > - Formally document the `.tasks/` orphan worktree pattern and cross-branch `git: <sha>` commit references in `doc/taskmark_spec.md`.
    > - Provide optional `tm sync` / auto-commit helper to commit changes in `.tasks/` to the orphan branch.
    > **Verify:** Clean worktree initialization, end-to-end task mutations on mounted worktree, and validation that `git status` on `main` ignores `.tasks/`.
    > **Completed:** 2026-11-08 git:54c6cf4
