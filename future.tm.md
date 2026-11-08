---
project: taskmark
status: Planned
date: 2026-11-08
---

## Validator Follow-ups
- [ ] Tighten `is_raw_html_start`'s V5 check to CommonMark's actual HTML-block conditions
    > **Context:** `tmval.lua`'s raw-HTML detection is still marginally wider than CommonMark: a line like `<foo bar` at column 0 is a paragraph under CommonMark but trips V5 here.
    > **Requirements:** Only worth doing if a false positive actually shows up in practice -- flagged as a known gap, not a bug with a confirmed impact.

## Hub and Spoke
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
