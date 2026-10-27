---
project: taskmark
status: Planned
date: 2026-10-27
---

## Task Movement Command(s)
- [ ] Develop simple commands for moving tasks between future.tm.md, active.tm.md, and completed.tm.md
    > **Context:** These are convenience commands to handle menial task movement between lists.
    > **Requirements:** Non destructive.  Never loses or corrupts individual tasks or task files.

    Considerations:

    - How to select a tasks using cli?  regex pattern? interactive select from list?
    - How to specify where to place it in the target file? Always inserted at top?  or Bottom?
    - To honor the non-destructive goal, copy the content to the new file.  Once it is
    confirmed to exist in the destination, then remove it from the source file.

## Validator/Archive Follow-ups
- [ ] Tighten `is_raw_html_start`'s V5 check to CommonMark's actual HTML-block conditions
    > **Context:** `tmval.lua`'s raw-HTML detection is still marginally wider than CommonMark: a line like `<foo bar` at column 0 is a paragraph under CommonMark but trips V5 here.
    > **Requirements:** Only worth doing if a false positive actually shows up in practice -- flagged as a known gap, not a bug with a confirmed impact.

- [ ] Decide whether an archive file's newly-appended tail should end without a trailing blank line
    > **Context:** `tmsweep_core.append_blocks` leaves one trailing blank line at the end of an archive file after appending. Verified it does not accumulate across repeated archive runs, so this is purely cosmetic.
    > **Requirements:** Confirm the desired end-of-file shape (with or without a trailing blank line) and adjust `append_blocks` only if it's worth the churn.

- [ ] Close the payload-boundary lazy-continuation gap (V13)
    > **Context:** V11 only checks payload freeform following a labeled field, so a payload whose last line is a labeled field followed immediately by top-level prose validates clean while CommonMark lazily continues the blockquote and swallows that prose into the field's value. The same absorption happens for a payload ending in prose or a bullet. Verified against the vendored cmark: §4.4.1's claim that top-level prose ends a payload is true for the line parser and false for CommonMark, which makes it a §1.2 subset violation rather than a lint gap.
    > **Requirements:** Add a spec rule and a matching validator rule (V13): a top-level prose line MUST NOT directly follow a payload line. Headings and task lines are exempt -- both interrupt a paragraph in CommonMark, verified -- so only prose needs the blank line. One boolean in `validate_body`, plus pass/fail fixtures.

## Hub and Spoke
- [ ] Define and implement `~` expansion for configured paths
    > **Context:** §10.1 ships `hub_dir: ~/tasks` as a default while §2.2.1 reads every value as literal text, and the spec never says who expands the `~`. `tmconfig.lua` returns the value literally; it builds `$HOME/.config` by hand for its own global-config path but expands nothing in a config value, so `io.open` on a hub path would fail. Not a live bug only because the hub is unimplemented -- it becomes one with the first hub task below.
    > **Requirements:** State in §10 that a tool expands a leading `~` in a path value via `$HOME`, and that the expansion is the tool's job rather than the reader's -- §2.2.1's literal-text rule stays unchanged. Expand in `tmconfig.resolve` so every consumer inherits it, and leave a value with no leading `~` byte-identical.

- [ ] Implement the registry file
    > **Context:** Spec §3.2 defines `registry.txt`: one absolute repository-root path per line, so the hub knows which repositories' `doc/tasks/` to include in the dashboard and in cross-project queries.
    > **Requirements:** Plain text, not Taskmark-formatted, and local to the machine that runs the tooling (never synced or committed). Blank lines and lines whose first non-space character is `#` are ignored. No format beyond that -- no per-line metadata, no aliasing.

- [ ] Implement dashboard generation
    > **Context:** Spec §7.2: the dashboard is a flattened, read-only view of pending work across every registered repository.
    > **Requirements:** For each path in the registry, read that repository's `active.tm.md` and emit its pending tasks under a heading naming the project. Regenerate `dashboard.tm.md` in full on every run; it is derived output, never read back by any tool, so nothing is lost by overwriting it.
    > **Considerations:** Payload blocks MAY be included or omitted -- a generation option, not a property of the format. Decide whether that's a flag or a config key before implementing.

- [ ] Implement inbox capture
    > **Context:** Spec §7.1: capturing a task from somewhere the repository isn't -- the point is that capture never blocks on getting the details right.
    > **Requirements:** Append `- [ ]` lines to `inbox.tm.md`. No routing decision, no tags, and no payload formatting are required; this is the capture profile (§1.3), so frontmatter is optional and the payload indentation rule isn't enforced there. A `+project` tag MAY be added when the destination is already obvious, to let triage pre-select it.

- [ ] Implement triage
    > **Context:** Spec §7.3: triage drains the inbox, bringing each captured task into strict form in a chosen repository.
    > **Requirements:** User-driven: present items one at a time, let the user edit the text and choose the destination (`future.tm.md` or `active.tm.md`), then remove the item from the inbox. A tool MAY auto-route only when unambiguous (e.g. a `+project` tag naming exactly one registered repository) but MUST fall back to asking, and MUST NOT guess from a partial match.
    > **Considerations:** The normalization step -- turning loosely-formatted captured text into a proper four-space payload -- is the `indent` filter, already built.
