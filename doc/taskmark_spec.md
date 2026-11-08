---
project: Taskmark
spec: SPEC-TASKMARK-03
author: Jason Lenz, Engenforge LLC
date: 2026-10-27
---

# Taskmark Specification (SPEC-TASKMARK-03)

Taskmark is a deterministic, multi-line, plain-text task format designed to work with any text editor and with automated stream-parsing tools. It takes the single-line simplicity of `todo.txt` and adds an attached block of arbitrary context beneath each task. It relies on strict structural anchors — a fixed task token, a fixed payload indent, and a fixed frontmatter boundary — so that conforming tools never need to build an abstract syntax tree.

## 1. Conformance and Notation

### 1.1 Requirement Levels

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are used as defined in RFC 2119. A document that violates any MUST is not a conforming Taskmark document. A tool that accepts such a document is not a conforming validator.

### 1.2 Relationship to CommonMark

**Taskmark is a strict subset of CommonMark.** Every conforming Taskmark document is a valid CommonMark document and renders correctly and legibly in any CommonMark renderer, with no plugin, extension, or custom parser. The converse does not hold: most CommonMark documents are not valid Taskmark.

Taskmark narrows CommonMark in two ways. It restricts which constructs may appear where — only certain block types at column 0, only one indentation width for attached content — and it assigns meaning to a few constructs CommonMark treats as ordinary text, such as the checkbox token and the `> **Key:** value` line.

This subset relationship is a hard constraint on the specification, not an aspiration. A rule that would make a conforming Taskmark file render incorrectly as CommonMark, or that would require a Markdown extension to display properly, does not belong in this format.

### 1.3 Profiles

Two conformance profiles exist. Every rule in this specification applies to the strict profile unless a rule names the capture profile explicitly.

* **Strict profile.** All repository (spoke) files: `active.tm.md`, `future.tm.md`, `completed.tm.md`, and `archive/<YYYY>/<YYYY-MM>.tm.md`. These are the documents a validator checks and the documents automation may safely rewrite.
* **Capture profile.** The hub inbox (§3.2). Text arrives here from constrained or hurried editing environments, so frontmatter is optional and the payload indentation rule is not enforced. Everything else about the format is unchanged. Triage (§7.3) brings captured text into strict form on the way into a repository.

### 1.4 Structure vs. Convention

This specification separates rules a validator enforces from conventions it does not. §§2–4 are enforceable structure. §§5–7 describe lifecycle operations and file semantics that tools implement and that a single file cannot be checked against. The priority flag (§4.3.1) and tags (§4.3.2) are optional extensions layered on the same grammar; a document that omits them entirely is fully conforming. §1.5 states exactly what a conforming validator checks.

### 1.5 Validator Obligations

A conforming validator MUST reject a strict-profile document for each of the following, and MUST NOT reject a document for anything else:

| # | Rule | § |
|---|------|---|
| V1 | Missing, unterminated, or non-first frontmatter block | 2.2 |
| V2 | A frontmatter line outside the flat `key: value` subset | 2.2.1 |
| V3 | A hard tab outside the content of a payload fenced code block | 2.4 |
| V4 | A non-ATX (setext) heading | 4.2 |
| V5 | A forbidden top-level block: fenced code, blockquote, thematic break, or raw HTML | 4.1 |
| V6 | A top-level list item starting with '-' that is not a well-formed task token | 4.3 |
| V7 | A payload line whose first four columns are not four literal spaces | 4.4.1 |
| V8 | Further leading whitespace past column 8 in payload content, or whitespace following a blank line outside a code fence | 4.4.1 |
| V9 | A task token appearing inside a payload block | 4.4.4 |
| V10 | A payload line beginning with '>' that does not match the labeled-field or continuation grammar | 4.4.2 |
| V11 | Freeform payload content following a labeled field with no blank line between them | 4.4.2 |
| V12 | A code fence opened in a payload block and not closed within it | 4.4.3 |

A validator MAY emit non-fatal warnings beyond this list — an unrecognized labeled-field key, a `status` value outside the enumeration in §2.3, a malformed date — but MUST NOT fail the document for them. Field-level conventions such as tag placement (§4.3.2) and labeled-field placement (§4.4.2) are never enforced.

## 2. File Format and Frontmatter

### 2.1 File Extension

Taskmark files MUST use the double extension `.tm.md` — `active.tm.md`, `completed.tm.md`, `inbox.tm.md`. The trailing `.md` guarantees that an editor without a Taskmark plugin falls back to ordinary Markdown rendering; the `.tm` segment gives a plugin a deterministic hook that costs no per-file sniffing of unrelated `.md` documents (§9).

The double extension means the POSIX basename minus one suffix is `active.tm`, not `active`. Tooling that derives display names from filenames SHOULD strip both suffixes.

### 2.2 Frontmatter Block

Every strict-profile document MUST begin with a frontmatter block:

* The first line of the file MUST be exactly `---`.
* The block MUST be terminated by a line that is exactly `---`.
* Nothing may precede the opening `---`, not even a blank line or a byte-order mark.
* Every line between the delimiters MUST match the flat subset defined in §2.2.1.

```markdown
---
project: myproject
status: Active
sprint: 2026-S3
date: 2026-07-07
---
```

The `---` delimiters are what every renderer that understands frontmatter already looks for — git forge previews, Pandoc, Hugo, Jekyll — so the block is parsed as metadata and hidden from rendered output with no renderer extension and no visual clutter.

In the capture profile the block is optional; when present it MUST follow these rules.

#### 2.2.1 The Flat Subset

YAML as a whole is far too large to be a dependency of a format that promises determinism. Taskmark therefore defines a deliberately small subset. Every line between the delimiters MUST be:

```text
key: value
```

* `key` matches `[A-Za-z][A-Za-z0-9_-]*` and is followed by a colon and exactly one space.
* `value` is the remainder of the line, with trailing whitespace stripped. It is read as literal text; Taskmark assigns no types. A value MAY be wrapped in matching single or double quotes, which a reader MUST strip — but quoting is not required and is conventionally omitted.
* Forbidden within the block: nesting or indentation of any kind, sequences (`- item`), flow collections (`[…]`, `{…}`), anchors and aliases (`&`, `*`), tags (`!`), directives (`%`), block scalars (`|`, `>`), comments, blank lines, and the `...` document-end marker.
* An unquoted value MUST NOT begin with `[`, `{`, `&`, `*`, `!`, `|`, `>`, or `%`, and MUST NOT contain a `#` preceded by whitespace. Each of those introduces a YAML construct this subset excludes, so a value needing one MUST be quoted.
* Keys are unordered; a duplicate key is an error.

The subset is small enough that reading it needs no library:

```lua
local key, value = line:match("^([%a][%w_-]*): (.*)$")
```

and large enough that a full YAML parser reads the same block to the same values. That two-way property is the point: minimal tools stay minimal, and every renderer already in the ecosystem works unmodified.

This is the only metadata syntax the specification defines. Configuration (§10) uses the same subset and the same reader, so a conforming implementation needs exactly one key/value parser and no serialization dependency of any kind.

### 2.3 Frontmatter Schema

```text
project: <repo-slug>
status: Active
sprint: YYYY-Sn
date: YYYY-MM-DD
```

* `project` — short identifier, conventionally the repository name. Required in spoke files; omitted in hub files, which are not scoped to one repository.
* `status` — one of `Active`, `Planned`, `Archive`, `Inbox`, `Dashboard`.
* `sprint` — sprint identifier, present only in `active.tm.md`. It MAY name several identifiers when concurrent sprints are in flight (§6.1). `completed.tm.md` and the monthly archives hold many sprints and name none; the most recent is already the first `## Sprint …` heading in the file.
* `date` — ISO 8601 calendar date (`YYYY-MM-DD`) on which the file was last structurally updated by a tool or by hand.

Per file:

| File | `project` | `status` | `sprint` | `date` |
|------|-----------|----------|----------|--------|
| `active.tm.md` | yes | `Active` | yes | yes |
| `future.tm.md` | yes | `Planned` | no | yes |
| `completed.tm.md` | yes | `Archive` | no | yes |
| `archive/<YYYY>/<YYYY-MM>.tm.md` | yes | `Archive` | no | yes |
| hub inbox | no | `Inbox` | no | yes |
| hub dashboard | no | `Dashboard` | no | yes |

Additional keys are permitted. A tool MUST preserve keys it does not recognize when it rewrites a file.

### 2.4 Encoding, Whitespace, and Line Length

* Files MUST be UTF-8 encoded and SHOULD use LF line endings.
* **Hard tabs are forbidden**, with one exception: payload *content* inside a fenced code block (§4.4.1). A tab's width is an editor setting, so wherever whitespace carries structure — frontmatter, headings, task lines, payload prose, labeled fields, and the payload indent itself — a tab would make the document parse differently for different readers. Fence content carries no structure and is never measured, so a tab there changes nothing for any parser. Spaces remain the encouraged style everywhere, including inside fences.
* Trailing whitespace on a line is not an error but SHOULD be stripped by tools that rewrite a file.
* A blank line is a line containing no characters. Because tabs are forbidden and trailing whitespace is meaningless, a line of only spaces is treated as blank.
* **There is no maximum line length and no hard-wrapping convention.** A paragraph, a task description, or a payload line is one logical line however long it runs; wrapping is a display decision belonging to the editor or viewer, not a property stored in the file. Hard-wrapped prose is not an error — a validator never inspects line length — but leaving lines unwrapped is the encouraged style, since it keeps a task line greppable in one piece and keeps diffs to the lines that actually changed.

## 3. Architecture

Taskmark uses a decoupled hub-and-spoke topology. The spoke holds the authoritative task data inside the git tree. The hub is an optional adjunct for working with tasks from outside a repository — capturing an item without opening the project, or reviewing work across several projects at once. There is no bidirectional synchronization anywhere in this specification; data flows one way on each path, so no conflict-resolution logic is ever required.

### 3.1 The Spoke — Local Repository

```text
[Project Repository Root]/
└── doc/
    └── tasks/
        ├── active.tm.md         <-- Current sprint: tasks being worked on now
        ├── future.tm.md         <-- Planned work not yet scheduled to a sprint
        ├── completed.tm.md      <-- Append-only archive, newest sprint first
        └── archive/             <-- Tool-managed: sections aged out of completed (§5.5)
            └── <YYYY>/
                └── <YYYY-MM>.tm.md
```

`archive/` is never hand-authored. It exists only once an aging tool has moved sections out of `completed.tm.md`; a repository with no aged-out sections has no `archive/` directory at all. These paths are conventions and may be overridden (§10).

### 3.2 The Hub — Cross-Repository Workspace

The hub is a directory, conventionally `~/tasks/`, holding no authoritative task data. It exists so that capture and review can happen away from any single repository — from a second machine, a shared or synchronized directory, a scripted export, a text editor open somewhere else, or a device that has no checkout at all. How its contents reach those places is outside this specification; a file-level sync tool, a shared volume, and a periodic copy are all equally valid.

The hub contains at most three files:

* **Inbox** (`inbox.tm.md`) — append-only from the capturing side, read-and-drain from the repository side. Tasks and raw thoughts are added here whenever opening the right repository is inconvenient or impossible, and consumed by triage (§7.3). Capture profile (§1.3).
* **Dashboard** (`dashboard.tm.md`) — generated output, read-only from the consuming side. Regenerated in full on each run (§7.2). Strict profile.
* **Registry** (`registry.txt`) — plain text, one absolute path per line, each naming the root of a repository whose `.tasks/` should be included in the dashboard and in cross-project queries. Blank lines and lines whose first non-space character is `#` are ignored. This file is not Taskmark-formatted and is local to the machine that runs the tooling.

Because the inbox is only ever appended to on one side and drained on the other, and the dashboard is only ever written on one side and read on the other, no file has two writers and the transport layer cannot produce a conflict.

## 4. Document Grammar

A Taskmark document is a sequence of lines. Below the frontmatter, every line is classified by its own leading characters alone — no enclosing context is required to decide what a line is. This is the property that lets a conforming parser run as a single pass with at most one variable of state (§8).

### 4.1 Top-Level Blocks

A **top-level** line is one that begins at column 0. After the frontmatter, only these top-level constructs are permitted:

* ATX headings (§4.2)
* task lines (§4.3)
* prose paragraphs
* blank lines

The following are forbidden at top level: fenced code blocks, blockquotes, thematic breaks (`---`, `***`, `___`), and raw HTML blocks.

Prose and blank lines are permitted because they cost a parser nothing — a line matching neither a heading nor a task token nor the payload indent is simply skipped — and because sprint summaries, warnings, and planning notes are genuinely useful at the top of a file. The four forbidden constructs share one defect: each can contain arbitrary verbatim text at column 0, including a line that looks exactly like `- [ ] something`. Excluding them from top level means a line matching the task token at column 0 is always a task, with no enclosing-block check. Verbatim material belongs in a payload code fence (§4.4.3), where its indentation already distinguishes it.

At column 0, `- ` is reserved strictly for task items (§4.3); a plain dash bullet (`- `) at top level is not permitted. Top-level prose lists MAY use `* `, `+ `, or ordered list markers (`1. `, `1) `). Sub-points and checklists for tasks belong in a payload (§4.4.3).

### 4.2 Headings

Headings MUST use ATX form (`#`, `##`, `###`, … followed by a space). Setext headings, underlined with `===` or `---`, are forbidden: they are ambiguous with the frontmatter delimiter and they require lookahead to recognize.

Any heading level is permitted. Headings are **flat contextual markers**, not structural parents: they carry no metadata, participate in no inheritance, and never nest tasks. A parser that wants to know which heading a task falls under needs one string variable, updated on each heading line — not a tree.

Heading *text* is never load-bearing. A tool that needs an insertion point (§5.4, §6.3) MUST locate it by position — the first heading line in the file — and MUST NOT match against particular wording.

### 4.3 The Task Line

```markdown
- [ ] (A) +api @backend Add rate limiting to the ingest endpoint
```

A task line has this grammar, at column 0:

```text
task     := token priority? description
token    := "- [ ] " | "- [x] "
priority := "(" [A-Z] ") "
```

* **Pending token:** `^- \[ \] ` — dash, space, left bracket, space, right bracket, space. The trailing space is part of the token.
* **Completed token:** `^- \[x\] ` — identical but with a lowercase `x`. Uppercase `X` is not accepted.
* The token is exactly six characters. Note that CommonMark sees only the leading `- ` as the list marker: `[ ]` is ordinary content that a renderer's task-list extension converts to a checkbox afterwards. The item's content column is therefore 2, which is what sets the payload indent in §4.4.1 — not the width of the token.

**All machine-readable metadata on a task lives on this one line.** Tools MUST NOT scan payload lines for tags or priority flags. A payload may contain a pasted JSON body, a stack trace, or a git log excerpt; treating those as metadata would silently poison every query. Confining the searchable surface to the task line also keeps filtering stateless — a filter evaluates one line and either emits it or drops it, with nothing buffered.

#### 4.3.1 Priority Flag (optional)

A single uppercase letter in parentheses MAY immediately follow the task token, followed by one space. Pattern: `^- \[[ x]\] \([A-Z]\) `.

* Exactly one letter; `A` denotes the highest priority.
* The flag is optional. When omitted, the token is followed by exactly one space and then the description — do not pad with spaces to align with prioritized tasks nearby.
* **Scope:** recognized only in this fixed position. `(A)` later in a description, in a payload, or in prose is ordinary text.
* The flag is **preserved after completion** (`- [x] (A) …`), so the archive retains the task's original urgency for later audit.
* Because the letter sits at a fixed column, ranking is a single `sort` over matching lines; no parsing beyond string slicing is required.

#### 4.3.2 Tags — `+project` and `@context`

Tags are ordinary words inside the description text. The grammar does not treat them specially and no parser change is needed to support them.

* `+tagname` marks a project or feature area. It maps naturally onto `future.tm.md` section headings (§6.2).
* `@tagname` marks execution context — `@backend`, `@cli`, `@review`.
* **Scope:** the task line only. The same words in a payload are prose.
* Because they are ordinary words, `grep -- '+api' active.tm.md` works with no tooling.
* A validator MUST NOT require or reject any particular tag shape; the description is free text.

**Placement is a user preference.** Tags may appear anywhere in the description — leading, trailing, or mid-sentence — and the format assigns no meaning to their position. There is no correct arrangement.

Tooling SHOULD extract tags from anywhere on the task line, so that filtering and sorting by tag work identically regardless of where a user puts them. A tool that can group by `+project` only when the tag happens to lead the description is a tool that has pushed its own convenience onto the user.

Position does have one consequence worth knowing, for users who prefer to sort with plain `sort` rather than dedicated tooling. Because every task line shares the same six-character token prefix, a lexicographic sort orders on whatever comes next, and by ASCII that is `(` (40) < `+` (43) < `@` (64) < letters. Leading tags therefore group tasks by tag, priority-flagged tasks sort ahead of the rest, and whichever sigil a user places first is the one that determines the grouping:

```markdown
- [ ] (A) +auth @backend Rotate the signing key
- [ ] +api @backend Add rate limiting to the ingest endpoint
- [ ] +api @cli Add a --rate-limit flag
- [ ] @review Read through the vendor contract
```

Users who want that behavior can choose a placement to suit it — projects first, contexts first, or whatever grouping they actually reach for. Users with tooling that extracts tags properly need not think about it.

### 4.4 The Payload Block

Extended detail — context, notes, stack traces, sub-steps, code — belongs directly beneath its task in a payload block.

#### 4.4.1 Indentation and Extent

Every payload line divides at column 4 into two parts, and Taskmark treats them completely differently:

* The **payload indent** is columns 1–4. It is structure, not text: it is what binds the line to its task. It MUST be four literal space characters on **every** payload line without exception, including the fence markers and every line of a fenced code block. A tab is never permitted here — a tab straddling the boundary where CommonMark is still consuming block indentation gets expanded to a four-column tab stop and partially absorbed, and requiring literal spaces keeps that case from arising.
* The **payload content** is everything from column 5 on. Taskmark never inspects it, never measures it, and never rewrites it. It may contain any indentation, any tabs, and any text whatsoever, including text that looks exactly like a task token or a heading.

This is the whole of the indentation rule. A validator checks that the four-column prefix is present and correct; it does not look past it. Being inside a fence changes nothing about the prefix, and nothing outside the prefix is ever checked.

One restriction applies to content outside a fenced code block: payload content MUST NOT begin with arbitrary leading whitespace past column 4, with one explicit exception: **active list items and their hanging continuation lines**. Inside an active list, deeper indentation up to column 8 (four spaces payload indent + up to 4 spaces content indent) is permitted for nested sub-bullets (`  - `, `  * `, `  + `, `  1. `) and hanging continuation lines directly following a list item. Indentation of 6 or more spaces (2+ spaces content indent) directly following a blank line outside a code fence remains strictly forbidden, as CommonMark would silently parse it as an unintended indented code block.
**Why four.** CommonMark sees the list marker as `- ` alone — one character plus one space — so the item's content column is 2, and an indented code block begins four columns past that, at column 6. A payload indent of 2, 3, 4, or 5 therefore parses as item content; **six or more silently becomes an indented code block**, which strips the payload of every structure this section defines: `> **Key:**` stops being a blockquote and lazily continues the task's own paragraph with a literal `>`, bullets stop being a list, and a code fence renders its backticks as text with no language applied. Four sits two columns clear of both bounds.

Where a payload begins and ends:

* **A payload block extends from the line after its task through the last line that is either blank or indented by four spaces.** Blank lines do not terminate a payload; a payload ends at the first non-blank line indented by fewer than four spaces — a heading, another task, or top-level prose — or at end of file.
* Blank lines inside a payload are not merely tolerated, they are required in places: CommonMark needs one to separate a fenced code block or a bullet list from a preceding paragraph.
* A payload is optional. A task with no payload is complete and conforming.

#### 4.4.2 Labeled Fields — `> **Key:** value`

Within a payload the leading `>` is reserved for exactly one purpose: a structured key/value field.

```markdown
- [ ] (A) +ops Renew TLS certificates
    > **Created:** 2026-08-01
    > **Due:** 2026-09-15
```

* Grammar: `^    > \*\*([A-Za-z][A-Za-z0-9_-]*):\*\* (.*)$`
* The leading `>` is CommonMark's blockquote marker. It puts the line into a distinct block type, which nearly every renderer and editor displays differently from a paragraph — a border, an indent, a muted color. This specification spends that visual distinction on structured data and on nothing else.
* **Labeled fields MAY span multiple lines.** Every continuation line of a labeled field MUST begin with `    > ` (four spaces payload indent followed by `> `). A parser concatenates the value across consecutive continuation lines with a single space. Unprefixed continuation lines remain strictly forbidden: CommonMark lazy continuation would absorb an unprefixed following line into the blockquote paragraph, making a wrapped value and following prose indistinguishable.
* A labeled-field run (including any multi-line continuation lines) MUST be followed by a blank line before any freeform payload content (Rule V11 in §1.5).
* A payload line beginning with `>` that does not match the labeled field start grammar or an immediate continuation line of an active labeled field — such as `> just a reminder` — is **not valid** (Rule V10).
* **Placement is free; one leading run is the canonical form.** A field is recognized anywhere in a payload. Like every other rule in this format, the classification comes from the line's own leading characters (§4.1), so a field that follows freeform content is fully conforming and a validator MUST NOT reject one for its position. Fields SHOULD nevertheless be written as a single contiguous run immediately beneath the task line, and a tool that adds a field — a `Completed` stamp on completion (§5.2), say — SHOULD insert it into that run rather than appending it below the freeform content. The reason is consistency across authoring tools rather than parsing: one habitual place to look keeps a task's metadata visible without reading its whole payload, and keeps a stamped field to a one-line diff. For the same reason, a tool that *reads* a field MUST search the whole payload and MUST NOT assume the canonical arrangement.

Registered keys:

| Key | Value | Notes |
|-----|-------|-------|
| `Completed` | `YYYY-MM-DD`, optionally followed by ` git:<sha>` | §5.2 |
| `Created` | `YYYY-MM-DD` | when the task was first entered |
| `Due` | `YYYY-MM-DD` | target completion date |
| `Context` | free text, one line | why the task matters |
| `Notes` | free text, one line | working detail |

**All task dates are labeled fields.** `Created`, `Due`, and `Completed` are the canonical and only forms this specification defines for the dates they name; there is no inline date syntax on the task line. One date convention, expressed one way, keeps extraction to a single pattern and keeps the task line reserved for the metadata that filtering and sorting actually use (§4.3).

Additional keys are permitted; a tool that does not recognize a key MUST preserve it and MUST NOT fail on it. Only `Completed` carries lifecycle meaning (§5).

#### 4.4.3 Freeform Content

Any payload line without a leading `>` is freeform: supporting detail for a human reader, never parsed as a field.

````markdown
- [ ] +api @backend Implement socket timeout handling
    > **Context:** Prevent hanging instances from dropped peers.

    Two call sites need this; the accept loop is the risky one.

    - check the accept path first
    - then the read path

    ```c
    struct timeval tv = { .tv_sec = 5, .tv_usec = 0 };
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) {
            return -1;
    }
    ```
````

Verbatim external material — a bug report, a stack trace, an email, a review comment — belongs in a fenced code block, not behind `>`. A fence preserves the source exactly, with no Markdown reflow or inline parsing, and it keeps `>` unambiguous as the labeled-field marker.

Fence content — everything past the payload indent (§4.4.1) — is verbatim in both directions: a tool MUST NOT rewrite it, reindent it, or expand tabs within it, and material taken back out of a payload MUST be byte-identical to what went in (§9.1). Adding or removing the four-column prefix is not a content edit and is always permitted. This is what makes the block safe for material whose whitespace is load-bearing — Go panic traces, `gofmt` output, and Makefile recipes all carry literal tabs that are wrong once expanded.

A fence opened inside a payload MUST be closed inside that payload. An unclosed fence splits the document's two readings apart: a line-oriented parser goes on seeing column-0 task lines below it, while CommonMark swallows them as code content. Closing every fence keeps the two readings identical.

#### 4.4.4 No Nested Tasks

A task token MUST NOT appear inside a payload block. Sub-steps are written as plain bullets — `- check the accept path first` — which read as a checklist for a human but carry no structure for a tool.

Nested tasks are excluded because they would break the two properties this format is built on. Filtering would need an inheritance rule: if a parent carries `+migration` and a child carries `@database`, either the parser maintains a stateful stack to push tags down the tree — the syntax tree this format exists to avoid — or the user duplicates every tag on every sub-task. Sorting would need a containment rule: a child extracted from its parent loses the context that made it legible, while dragging the parent along breaks the sort order.

The practical test: **if a sub-step needs its own tags, its own priority, or its own completion hash, it has outgrown being a sub-step and should be promoted to a top-level task.**

## 5. Task Lifecycle

This section describes the working practices Taskmark is shaped around and the operations tooling is expected to provide. **None of it is required.** Taskmark defines a file format, not a methodology: any workflow that keeps the files conforming to §§2–4 is valid, whether or not it uses sprints, sweeps, or archives at all. A user who keeps a single `active.tm.md` by hand and never rotates anything is using Taskmark correctly.

### 5.1 Session Start

At the beginning of a working session, read `.tasks/active.tm.md` and choose the first pending (`- [ ]`) task with no unmet dependencies. Consult `future.tm.md` when context on upcoming work is needed.

### 5.2 Completing a Task

1. Commit the associated code changes, if any.
2. Change the token from `- [ ] ` to `- [x] ` in place. Preserve the priority flag.
3. Add a `Completed` field to the task's payload:

```markdown
- [x] +api Implement socket timeout handling
    > **Completed:** 2026-07-07 git:a1b2c3d

- [x] Review and sign off on the vendor contract
    > **Completed:** 2026-07-07
```

The `Completed` field MUST carry an ISO date. The short git hash of the implementing commit (`git:<sha>`, 7–40 hex characters) MUST be present whenever the task involved a commit, so the archive stays auditable against history, and MUST be omitted for a task completed outside of coding.

A recorded hash names the commit as it stood when the task was stamped. Rewriting history afterward — squash, amend, rebase — can leave it pointing at nothing. Taskmark neither detects nor repairs this, so it is worth keeping in mind when stamping work that has not yet reached its final form.

The completed task stays in place in `active.tm.md` until it is swept.

### 5.3 Sweep

A **sweep** moves every `- [x]` task and its payload out of `active.tm.md` and into `completed.tm.md`. Sweeping operates on individual tasks, not on sections: a sprint with one unfinished task does not hold nine finished ones in the active file.

The sweep is a single streaming pass:

1. Read `active.tm.md` line by line.
2. On a `- [ ] ` task, copy the task and its payload to the replacement active file.
3. On a `- [x] ` task, buffer the task and its payload for the archive.
4. On any other line, copy it to the replacement active file.
5. Insert the buffered tasks into `completed.tm.md` (§6.3), then replace `active.tm.md`.

A task and its payload move as one unit; the payload's extent is defined in §4.4.1.

Removing a task from the middle of a list leaves the blank lines that surrounded it behind, so a tool that rewrites a file MUST normalize blank lines outside fenced code blocks: collapse any run of consecutive blank lines to one, and drop trailing blank lines at end of file. Runs of blank lines carry no meaning in CommonMark, and without this rule repeated sweeps accumulate vertical whitespace. Blank lines *inside* a fenced code block are content and MUST be preserved exactly.

Original headings are **not** copied into `completed.tm.md`. Active work is grouped topically for planning; completed work is grouped chronologically for audit. Copying topical headings into the archive would scatter fragmentary duplicates of them throughout it. A task that becomes unclear once separated from its heading is a task whose description was leaning on that heading — `+project` and `@context` tags exist to make a task self-standing.

Headings and top-level prose in `active.tm.md` are never swept and are never automatically deleted, including when every task beneath them has been swept away. In keeping with the minimalist goals of the format, removing a heading left empty by a sweep is left to the user, if it is wanted at all.

### 5.4 Sprint Rotation

At a sprint boundary, or whenever `active.tm.md` grows unwieldy:

1. Sweep (§5.3).
2. Update `sprint` and `date` in the `active.tm.md` frontmatter, and `date` in `completed.tm.md`.

Rotation touches `active.tm.md` and `completed.tm.md` only. **`future.tm.md` is not part of rotation.** Moving a task from planned work into the active sprint is always a deliberate user decision — it is what sprint planning *is* — and no tool selects, promotes, or moves those tasks on the user's behalf. A tool MAY offer to open `future.tm.md`, or to move one named task the user has chosen, but it MUST NOT promote tasks by any automatic rule.

A rotated section carries no date of its own. A section's age derives from the most recent `Completed` date among its own tasks (§5.5). One date convention per task is sufficient; a section-level rotation timestamp would record only when a section happened to move, which says nothing about the work.

### 5.5 Archive Aging

A section ages out of `completed.tm.md` when it is **both** outside the ten most recent sections **and** its most recent `Completed` date is more than fourteen days old. Both thresholds are tool defaults and MAY be configurable; the rule that age derives from the tasks' own `Completed` stamps is normative.

An aged-out section is appended **verbatim** — its heading and every task and payload line unchanged — to `archive/<YYYY>/<YYYY-MM>.tm.md`, where the year and month come from that same most recent `Completed` date. Multiple sections may land in one monthly file. Archive files are append-only and are never rewritten.

## 6. File Conventions

### 6.1 `active.tm.md` — Current Sprint

Normally one sprint under a single `# Current Sprint` heading. Keep the file short enough that all active work fits on one screen.

```markdown
---
project: myproject
status: Active
sprint: 2026-S3
date: 2026-07-07
---

# Current Sprint

Bootstrap work is blocked on the vendor contract; start with the socket path.

- [ ] (A) +net First task
    - Sub-bullet with detail

- [ ] +cli Second task
    > **Context:** Why this matters.
```

When concurrent sprints are in flight, separate them with H2 headings and list every identifier in the `sprint` field:

```markdown
---
project: myproject
status: Active
sprint: 2026-S3a / 2026-S3b
date: 2026-07-07
---

# Active Sprints

## Sprint Name A

- [ ] Task belonging to sprint A

## Sprint Name B

- [ ] Task belonging to sprint B
```

### 6.2 `future.tm.md` — Planned Work

Groups planned tasks by theme using H2 headings. The `+tag` convention (§4.3.2) maps naturally onto section names. No `sprint` field.

Tasks leave this file only when the user moves them into `active.tm.md` (§5.4). Nothing in the format or the tooling promotes them automatically.

```markdown
---
project: myproject
status: Planned
date: 2026-07-07
---

# Planned Work

## Feature Area

- [ ] +feature Planned task with detail
    - Sub-point

## Another Area

- [ ] +other Another planned task
```

### 6.3 `completed.tm.md` — Chronological Archive

Append-only, newest sprint first. On each sweep, insert a new H2 section immediately after the file's first heading line, so the most recent work stays at the top. Older sections are never modified.

```markdown
---
project: myproject
status: Archive
date: 2026-08-30
---

# Completed Archive

## Sprint 2026-S3

- [x] (A) +api Most recently completed task
    > **Completed:** 2026-08-30 git:abc1234

## Sprint 2026-S2

- [x] +cli Older completed task
    > **Completed:** 2026-07-05 git:def5678
```

The heading text `# Completed Archive` is conventional, not load-bearing (§4.2): a tool finds the insertion point as "after the first heading line", whatever it says. If a section for the current sprint already exists at the top, a sweep appends into it rather than creating a duplicate.

Two branches that both sweep will conflict here, since both insert at the same anchor. The conflict is always safe to resolve by keeping both sections: the file is append-only, sections are independent, and only their order is at stake.

### 6.4 `archive/<YYYY>/<YYYY-MM>.tm.md` — Aged Sections

Tool-managed, never hand-authored. Sections arrive here by the aging rule in §5.5, each keeping its original heading and content verbatim. No `sprint` field — a monthly file is not scoped to one sprint.

The filename repeats the year — `archive/2026/2026-01.tm.md` — so that every archive file identifies its own period without reference to the directory holding it. A file copied, attached, or opened on its own is still unambiguous.

```markdown
---
project: myproject
status: Archive
date: 2026-08-27
---

# Archived Tasks — 2026-01

## Sprint 2025-S12

- [x] +net Task completed the prior January
    > **Completed:** 2026-01-15 git:9f1e2a3
```

## 7. Hub Workflow

The hub (§3.2) supports two operations that a single repository cannot: capturing a task from somewhere the repository is not, and reviewing work across every repository at once. Both are optional; a user who works only inside repositories never needs a hub at all.

### 7.1 Capture

When opening the right repository is inconvenient or impossible, append `- [ ]` lines to the inbox. No routing decision, no tags, and no payload formatting are required — the inbox is the capture profile (§1.3), and the point is that capture never blocks on getting the details right. A `+project` tag MAY be added when the destination is already obvious, to let triage pre-select it.

### 7.2 Dashboard Generation

The dashboard is a flattened view of pending work across repositories. For each path in the registry (§3.2), read that repository's `active.tm.md` and emit its pending tasks under a heading naming the project.

Payload blocks MAY be included or omitted. Including them preserves each task's context and is often what makes the dashboard useful on its own; omitting them produces a compact list that suits a small screen or a quick scan. This is a generation option, not a property of the format — both forms are conforming Taskmark.

The dashboard is derived data. It is overwritten in full on every generation and is never read back by any tool, so edits made to it do not survive and do not reach any repository. Reviewing tasks happens here; changing them happens in the repository.

### 7.3 Triage

Triage drains the inbox. Each captured task is appended to a chosen repository's `future.tm.md` or `active.tm.md`, brought into strict form (§1.3), and then removed from the inbox.

**Triage is a user-driven operation.** Captured text arrives from hurried or constrained editing and will often be terse, misspelled, missing tags, or ambiguous as to which project it belongs to; deciding what a captured line actually means and where it belongs is exactly the judgment the capture step deferred. Tooling SHOULD present items one at a time and let the user edit the text and choose the destination. A tool MAY route an item automatically when it is unambiguous — a `+project` tag naming exactly one registered repository, for instance — but MUST fall back to asking, and MUST NOT guess a destination from partial matches.

Triage is the only operation that reads the inbox and the only one that writes into a repository from the hub. Nothing is written back toward the capture side except the regenerated dashboard, so no file has two writers.

## 8. Parsing Model

Because frontmatter, headings, task tokens, and the payload indent are each identifiable from a line's own leading characters, a conforming reader is a single pass with one variable of state — the current heading, per §4.2. No abstract syntax tree is required.

```lua
-- Schematic Taskmark reader. One pass, one variable of state.
local heading, in_fm, fm_done, meta = nil, false, false, {}

for line in io.lines(".tasks/active.tm.md") do
    if not fm_done and line == "---" then
        if in_fm then fm_done = true else in_fm = true end
    elseif in_fm then
        local key, value = line:match("^([%a][%w_-]*): (.*)$")
        meta[key] = value
    elseif line:match("^#+ ") then
        heading = line:match("^#+ (.*)")
    elseif line:match("^%- %[[ x]%] ") then
        print("TASK", heading, line)
    elseif line:match("^    ") then
        print("  PAYLOAD", line:sub(5))
    end
    -- anything else (blank line, top-level prose) is skipped
end
```

A tool that only needs the task lines can skip the heading variable entirely and match `^- \[[ x]\] ` with `grep`, `sed`, or `awk`.

## 9. Editor Integration

Taskmark's grammar is fixed enough that syntax highlighting, folding, and completion can be implemented with regex-based rules or a small Tree-sitter grammar. No language server is needed, and none should be built.

A conforming editor integration SHOULD name its filetype `taskmark` and SHOULD activate on any of the following:

1. **Extension glob** — `*.tm.md`. This is the primary trigger (§2.1).
2. **Path glob** — files inside a configured tasks directory, `*/.tasks/*` by default (§10), which catches a project that has renamed its task files.
3. **Content signature** — a first line of exactly `---` followed within the block by a `project:` or `status:` line. A plugin may read the first few lines of a buffer and set the filetype from this alone.

### 9.1 Authoring Aids

Most of the friction in writing Taskmark by hand comes from defaults an editor applies to ordinary Markdown. An integration SHOULD, for filetype `taskmark`:

* **Continue a task into its payload at four spaces.** No editor's default list continuation produces this, and it is needed on every payload line, which makes it the single highest-value thing a plugin can do.
* **Disable automatic hard wrapping.** Taskmark has no line-length limit (§2.4), and an editor that wraps a long `> **Key:** value` line silently produces an invalid document (§4.4.2) from a setting the user has forgotten is on.
* **Expand tabs on insert outside fenced code blocks**, and leave fence content untouched (§4.4.3).
* **Fold payload blocks and completed sections**, both of which are identifiable from indentation and the task token alone.

Moving material in and out of a payload — a stack trace, a diff, a block of source — is the one case an editor cannot help with generically, since the text carries its own indentation and must gain or shed the payload prefix without losing it. A tool SHOULD therefore provide a **payload indent filter and its inverse**, both plain stdin-to-stdout filters:

* **Indent** prefixes every non-blank line with the four-space payload indent and emits blank lines as genuinely empty, so no line is left holding four spaces of trailing whitespace (§2.4). It changes nothing else. It MAY wrap the result in a fence with a given info string.
* **Dedent** removes exactly four leading spaces from each line and changes nothing else. It MUST fail rather than truncate when a non-blank line does not carry the full four-space prefix — that is the case where the selection has picked up a task line or top-level prose, and silently eating characters from it is the one way this operation can destroy data. It MAY additionally drop the opening and closing fence markers, which is usually what is wanted when lifting a code block back out to a file or a compiler.

The two MUST round-trip: dedent after indent returns the input byte for byte, for any input whatsoever. That is what gives §4.4.3's verbatim guarantee something to stand on. Whitespace-sensitive material — Makefile recipes, tab-indented Go, a diff whose leading spaces are significant — goes into a payload and comes back out unchanged, rather than being merely *stored* faithfully and then mangled on the way out.

**Known erratum:** "for any input whatsoever" overstates it for a line-oriented filter. Input with no trailing newline gains one on the round trip, since a trailing newline is not itself a line these filters read or emit. This is a gap in the spec's wording, not license to accept the mismatch silently; an implementation that leaves it unfixed MUST say so.

Keeping these as filters rather than editor features is what makes them universal: they compose with the shell (`tm indent < trace.txt`, `xclip -o | tm indent`, `tm dedent > patch.diff`) and, more usefully, with any editor that can pipe a region through an external command, which covers essentially all of them. No plugin is required to get the behavior, and neither filter needs a parser or any state.

The indent filter is also the normalization step triage performs (§7.3) when it moves captured text into a repository; the two are the same operation.

### 9.2 Modelines

For a file opened outside any of the triggers above, a standard modeline in a trailing HTML comment forces the filetype explicitly and is invisible in rendered Markdown:

```markdown
<!-- vim: set ft=taskmark : -->
```

An editor with no Taskmark plugin renders every one of these files as ordinary Markdown with a hidden frontmatter block and interactive checkboxes. Nothing about the format depends on tooling being installed.

## 10. Configuration

By default a Taskmark tool operates entirely on the conventional paths above; no configuration file is required and initialization never creates one. Configuration exists so a project or a user can move those paths, and it does nothing else (§10.3).

### 10.1 Files

Configuration uses the **same flat `key: value` subset as frontmatter** (§2.2.1), so an implementation parses it with the reader it already has. The same schema is read from two locations:

* **Global** — `$XDG_CONFIG_HOME/taskmark/config`, defaulting to `~/.config/taskmark/config` when `XDG_CONFIG_HOME` is unset. Settings belonging to the user rather than to any one repository, such as the hub location.
* **Local** — `.taskmarkrc` in the directory the tool is invoked from. Settings belonging to one project.

```text
# paths for this project
tasks_dir: .tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive

hub_dir: ~/tasks
inbox_file: inbox.tm.md
dashboard_file: dashboard.tm.md
registry_file: registry.txt
```

Two relaxations apply here and not in frontmatter, matching the rule already used for the registry (§3.2): **blank lines and comment lines** — those whose first non-space character is `#` — are ignored. A configuration file is hand-edited far more often than frontmatter, and being able to note why a path was overridden is worth two lines in a reader. Every other rule of §2.2.1 holds unchanged, including that values are read as literal text.

Every value is a scalar, and that is a deliberate limit rather than an omission: configuration never grows nested structure. Where a setting is genuinely a list, it lives in its own line-oriented file that the configuration merely points at — `registry_file` is the existing example.

All keys are optional in both files. An absent key, an absent file, or a line a reader cannot parse falls back silently to the next source below, so a project with no configuration behaves exactly as one with an empty file.

### 10.2 Resolution Order

Resolution is **per key**, not per file: a local file that sets only `tasks_dir` leaves every other key to the global file and the built-in defaults. For each path a tool needs, highest priority first:

1. **Explicit command-line arguments** — a `--tasks-dir DIR` option, or a file path passed positionally to a subcommand that accepts one. These bypass both configuration files for the paths they name.
2. **Local `.taskmarkrc`** in the current working directory.
3. **Global configuration file.**
4. **Built-in defaults** — the conventional paths used throughout this specification.

**Legacy task directory.** Before SPEC-TASKMARK-04 the default `tasks_dir` was `doc/tasks`. When no source above sets `tasks_dir`, `.tasks/` does not exist, and `doc/tasks/` does, a tool SHOULD resolve `tasks_dir` to `doc/tasks` so that an existing project keeps working unconfigured. Once `.tasks/` exists, or `tasks_dir` is set anywhere, the fallback never applies.

### 10.3 Scope

Configuration controls *where* a tool reads and writes the files this specification defines. It does not change file contents, task grammar, or any other rule in this document. `archive_dir` renames only the top-level folder; the `<YYYY>/<YYYY-MM>.tm.md` layout beneath it is fixed.

## 11. Isolation and Portability

Task data lives inside `.tasks/` relative to the repository root, so it travels with the repository through clones, containers, and sandboxes with no external path hierarchy, no global data store, and no network service. A project's tasks are as private as its source, and history for both is the same history.

The hub does not weaken this. It stores no authoritative data, and the dashboard is derived output that can be regenerated or deleted at any time without loss.
