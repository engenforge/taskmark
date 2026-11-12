---
project: Taskmark
spec: SPEC-TASKMARK-05
author: Jason Lenz, Engenforge LLC
date: 2026-11-12
---

# Taskmark Specification (SPEC-TASKMARK-05)

Taskmark is a deterministic, multi-line, plain-text task format designed to work with any text editor and with automated stream-parsing tools. It takes the single-line simplicity of `todo.txt` and adds an attached block of arbitrary context beneath each task. It relies on strict structural anchors — a fixed task token, a fixed payload indent, and pure CommonMark block separation — so that conforming tools never need to build an abstract syntax tree.

SPEC-TASKMARK-05 extends SPEC-TASKMARK-04 without changing its grammar or its validator rules: every SPEC-TASKMARK-04 document conforms unchanged. It adds the optional task identifier (§4.3.3) and the `Depends` field (§4.4.2), and states the order of work and how a session selects a task (§5.1).

## 1. Conformance and Notation

### 1.1 Requirement Levels

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are used as defined in RFC 2119. A document that violates any MUST is not a conforming Taskmark document. A tool that accepts such a document is not a conforming validator.

### 1.2 Relationship to CommonMark

**Taskmark is a strict subset of CommonMark.** Every conforming Taskmark document is a valid CommonMark document and renders correctly and legibly in any CommonMark renderer, with no plugin, extension, or custom parser. The converse does not hold: most CommonMark documents are not valid Taskmark.

Taskmark narrows CommonMark in two ways. It restricts which constructs may appear where — only certain block types at column 0, only one indentation width for attached content — and it assigns meaning to a few constructs CommonMark treats as ordinary text, such as the checkbox token and the `> **Key:** value` line.

This subset relationship is a hard constraint on the specification, not an aspiration. A rule that would make a conforming Taskmark file render incorrectly as CommonMark, or that would require a Markdown extension to display properly, does not belong in this format. In particular, Taskmark documents are pure CommonMark without YAML frontmatter, starting immediately on line 1 with standard Markdown headings.

### 1.3 Conformance Profile

All repository task files — `active.tm.md`, `future.tm.md`, `completed.tm.md`, and `archive/<YYYY>/<YYYY-MM>.tm.md` — are strict-profile pure CommonMark documents. These are the documents a validator checks and the documents automation may safely rewrite.

### 1.4 Structure vs. Convention

This specification separates rules a validator enforces from conventions it does not. §§2–4 are enforceable structure. §§5–6 describe lifecycle operations and file semantics that tools implement and that a single file cannot be checked against. The priority flag (§4.3.1), tags (§4.3.2), and the task identifier (§4.3.3) are optional extensions layered on the same grammar; a document that omits them entirely is fully conforming. §1.5 states exactly what a conforming validator checks.

### 1.5 Validator Obligations

A conforming validator MUST reject a strict-profile document for each of the following, and MUST NOT reject a document for anything else:

| # | Rule | § |
|---|------|---|
| V3 | A hard tab outside the content of a payload fenced code block | 2.3 |
| V4 | A non-ATX (setext) heading | 4.2 |
| V5 | A forbidden top-level block: fenced code, blockquote, thematic break, or raw HTML | 4.1 |
| V6 | A top-level list item starting with '-' that is not a well-formed task token | 4.3 |
| V7 | A payload line whose first four columns are not four literal spaces | 4.4.1 |
| V8 | Further leading whitespace past column 8 in payload content, or whitespace following a blank line outside a code fence | 4.4.1 |
| V9 | A task token appearing inside a payload block | 4.4.4 |
| V10 | A payload line beginning with '>' that does not match the labeled-field or continuation grammar | 4.4.2 |
| V11 | Freeform payload content following a labeled field with no blank line between them | 4.4.2 |
| V12 | A code fence opened in a payload block and not closed within it | 4.4.3 |
| V13 | Top-level prose directly following a task line or payload line without an intervening blank line | 4.4.5 |
| V14 | A leading frontmatter block (`---` … `---`) | 2.2 |

A validator MAY emit non-fatal warnings beyond this list — an unrecognized labeled-field key, a malformed date, a second `**Key:**` inside a field's value (§4.4.2), an identifier carried by two tasks (§4.3.3) — but MUST NOT fail the document for them. Field-level conventions such as tag placement (§4.3.2) and labeled-field placement (§4.4.2) are never enforced.

## 2. File Format and Structure

### 2.1 File Extension

Taskmark files MUST use the double extension `.tm.md` — `active.tm.md`, `completed.tm.md`, `future.tm.md`. The trailing `.md` guarantees that an editor without a Taskmark plugin falls back to ordinary Markdown rendering; the `.tm` segment gives a plugin a deterministic hook that costs no per-file sniffing of unrelated `.md` documents (§8).

The double extension means the POSIX basename minus one suffix is `active.tm`, not `active`. Tooling that derives display names from filenames SHOULD strip both suffixes.

### 2.2 Pure CommonMark Structure

Every conforming Taskmark document starts immediately on line 1 with a CommonMark heading (`#` or `##`) or top-level content.

* Taskmark task documents MUST NOT contain YAML or other frontmatter blocks (`---`).
* A leading `---` delimiter parses in CommonMark as a thematic break (`<hr />`), and the `key: value` lines beneath it as a setext heading. A validator MUST report such a block — line 1 is `---`, followed by blank, `#` comment, or `key: value` lines up to a closing `---` or `...` — once, as Rule V14, rather than as the V4/V5 violations its lines would otherwise raise, so that a document written for SPEC-TASKMARK-03 or earlier gets a diagnostic that names the actual change. A repair tool MAY simply delete the block.
* An empty file is a conforming document with no tasks.
* Static project and directory configuration is maintained externally in `.taskmarkrc` (§9), completely decoupled from the Markdown task files.

### 2.3 Encoding, Whitespace, and Line Length

* Files MUST be UTF-8 encoded and SHOULD use LF line endings.
* **Hard tabs are forbidden**, with one exception: payload *content* inside a fenced code block (§4.4.1). A tab's width is an editor setting, so wherever whitespace carries structure — headings, task lines, payload prose, labeled fields, and the payload indent itself — a tab would make the document parse differently for different readers. Fence content carries no structure and is never measured, so a tab there changes nothing for any parser. Spaces remain the encouraged style everywhere, including inside fences.
* Trailing whitespace on a line is not an error but SHOULD be stripped by tools that rewrite a file.
* A blank line is a line containing no characters. Because tabs are forbidden and trailing whitespace is meaningless, a line of only spaces is treated as blank.
* **There is no maximum line length and no hard-wrapping convention.** A paragraph, a task description, or a payload line is one logical line however long it runs; wrapping is a display decision belonging to the editor or viewer, not a property stored in the file. Hard-wrapped prose is not an error — a validator never inspects line length — but leaving lines unwrapped is the encouraged style, since it keeps a task line greppable in one piece and keeps diffs to the lines that actually changed.

## 3. Architecture and Directory Layout

Taskmark task management is self-contained within a dedicated directory, conventionally `.tasks/` relative to the repository root:

```text
[Project Repository Root]/
└── .tasks/
    ├── active.tm.md         <-- Current sprint: tasks being worked on now
    ├── future.tm.md         <-- Planned work not yet scheduled to a sprint
    ├── completed.tm.md      <-- Reverse-chronological archive, newest work first
    └── archive/             <-- Tool-managed: sections aged out of completed (§5.5)
        └── <YYYY>/
            └── <YYYY-MM>.tm.md
```

`archive/` is never hand-authored. It exists only once an aging tool has moved sections out of `completed.tm.md`; a repository with no aged-out sections has no `archive/` directory at all. These paths are conventions and may be overridden (§9).

## 4. Document Grammar

A Taskmark document is a sequence of lines. Every line is classified by its own leading characters alone — no enclosing context is required to decide what a line is. This is the property that lets a conforming parser run as a single pass with at most one variable of state (§7).

### 4.1 Top-Level Blocks

A **top-level** line is one that begins at column 0. Only these top-level constructs are permitted:

* ATX headings (§4.2)
* task lines (§4.3)
* prose paragraphs
* blank lines

The following are forbidden at top level: fenced code blocks, blockquotes, thematic breaks (`---`, `***`, `___`), and raw HTML blocks.

Prose and blank lines are permitted because they cost a parser nothing — a line matching neither a heading nor a task token nor the payload indent is simply skipped — and because sprint summaries, warnings, and planning notes are genuinely useful at the top of a file. The four forbidden constructs share one defect: each can contain arbitrary verbatim text at column 0, including a line that looks exactly like `- [ ] something`. Excluding them from top level means a line matching the task token at column 0 is always a task, with no enclosing-block check. Verbatim material belongs in a payload code fence (§4.4.3), where its indentation already distinguishes it.

At column 0, `- ` is reserved strictly for task items (§4.3); a plain dash bullet (`- `) at top level is not permitted. Top-level prose lists MAY use `* `, `+ `, or ordered list markers (`1. `, `1) `). A list item that wraps onto a second line continues at column 0, where CommonMark's lazy continuation keeps the line in the item; an indented continuation line is not top-level and is rejected (V7). Sub-points and checklists for tasks belong in a payload (§4.4.3).

### 4.2 Headings

Headings MUST use ATX form (`#`, `##`, `###`, … followed by a space). Setext headings, underlined with `===` or `---`, are forbidden: they require lookahead to recognize and conflict with pure CommonMark stream parsing.

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

**All machine-readable metadata on a task lives on this one line.** Tools MUST NOT scan payload lines for tags, priority flags, or a task's own identifier. The one payload content a tool reads for selection is a `Depends` field (§4.4.2): it names *other* tasks, by the identifier on their own task lines, and is read as a labeled field, never by searching the payload's text. A payload may contain a pasted JSON body, a stack trace, or a git log excerpt; treating those as metadata would silently poison every query. Confining the searchable surface to the task line also keeps filtering stateless — a filter evaluates one line and either emits it or drops it, with nothing buffered.

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

#### 4.3.3 Identifier — `id:` (optional)

A task MAY carry one identifier: a word made of `id:` followed by four or more lowercase letters and digits. Pattern, for the word: `^id:[0-9a-z]{4,}$`.

```markdown
- [ ] +api Add rate limiting to the ingest endpoint id:k7q2x
    > **Depends:** id:m3x8a
```

* **Purpose.** The identifier is the one name for a task that survives edits to its text. It stays on the line when the task moves between files, is completed, swept, and archived, so it is what a `Depends` field (§4.4.2), a commit message, a review note, or a conversation can cite.
* **An ordinary word.** Like a tag, it is part of the description: the grammar does not treat it specially, it may sit anywhere on the line, and a validator MUST NOT require or reject one. If a line holds several such words, the first is the task's identifier.
* **Scope:** only a word on the task line identifies a task. The same word in a payload or in prose is a reference to that task.
* **Never changed, never reused.** Once written, an identifier stays with its task. An identifier is cited from places the task files cannot reach — commit messages (§10.3), review notes, other repositories — and those citations are permanent: a commit cannot be rewritten after it is published. Changing or reusing an identifier silently breaks every one of them. A new task SHOULD NOT be given an identifier that already occurs anywhere in the task files — on a task line or in a reference, including `completed.tm.md` and the archive — so that a new task can never satisfy an old reference. This binds whoever assigns an identifier: a tool that assigns one MUST check it against every task file first. It is not a rule a single document is validated against (§1.4).
* **Drawn at random, or carried over.** Tools SHOULD assign identifiers (the reference CLI's `tm add` and `tm id` do), drawing each at random and checking the candidate against every task file before writing it. A sequential number needs a counter, and two branches that each take "the next number" collide silently; a random draw needs no shared state. The reference CLI draws five characters from a 32-symbol alphabet that omits `i`, `l`, `o`, and `u`, so no symbol can be mistaken for another. The cost is that a drawn identifier means nothing and is hard to say aloud or remember; a project that refers to tasks by number in conversation pays for collision safety in readability.
* **Hand-chosen identifiers.** An identifier chosen by a person or derived from an existing scheme is equally valid, provided it is unused and fits the pattern. A project with its own numbering carries it over by rewriting each number into the form — `Z-0114` becomes `id:z0114` — and drawn and carried-over identifiers then coexist in the same files. A tool that adds a task whose text already carries an identifier SHOULD keep it rather than stamp a second one, and SHOULD refuse it if it is already in use (the reference CLI's `tm add` does both).
* **Uniqueness is a convention.** It spans files, so no validator can enforce it on one document (§1.4). Two tasks end up with one identifier when a task is copied, or — rarely — when two branches draw the same value before they merge. Tools SHOULD warn about it; the repair is to give one of the tasks a new identifier and correct the references meant for it.
* **Optional.** A task without an identifier is fully conforming and is addressed by its text. Completed tasks that predate the convention SHOULD otherwise be left as they are: completed text is a record.
* **Adopting identifiers.** A project starting to use identifiers, or `Depends`, has completed work that open tasks may name. Since a dependency on a task no line carries is unmet (§5.1), one of two things is needed, done once: give those completed tasks identifiers as part of the migration — carrying over an existing number does exactly this, and is the one edit to completed text this specification endorses — or drop the `Depends` entries that name work already complete, which by definition no longer blocks anything. A migration that does neither leaves tasks that `tm next` never selects.

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

* **One field per line.** A value runs to the end of its line (and through any continuation lines), so a second `**Key:**` on the same line is text inside the first field's value, not a field. `> **Created:** 2026-11-07. **Branch:** testinfra` is a single `Created` field whose value is not a date; `Branch` is not a field at all. Write each field on a line of its own.

Registered keys:

| Key | Value | Notes |
|-----|-------|-------|
| `Completed` | `YYYY-MM-DD`, optionally followed by ` git:<sha>` | §5.2 |
| `Created` | `YYYY-MM-DD` | when the task was first entered |
| `Due` | `YYYY-MM-DD` | target completion date |
| `Depends` | one or more task identifiers (`id:k7q2x`, §4.3.3), optionally with free text | tasks that must be completed before this one can start; §5.1 |
| `Context` | free text, one line | why the task matters |
| `Notes` | free text, one line | working detail |

**All task dates are labeled fields.** `Created`, `Due`, and `Completed` are the canonical and only forms this specification defines for the dates they name; there is no inline date syntax on the task line. One date convention, expressed one way, keeps extraction to a single pattern and keeps the task line reserved for the metadata that filtering and sorting actually use (§4.3).

Additional keys are permitted; a tool that does not recognize a key MUST preserve it and MUST NOT fail on it. Only `Completed` and `Depends` carry lifecycle meaning (§5).

**Reading `Depends`.** A tool takes every `id:` word in the value as a dependency and ignores everything else, so a reason may sit beside a blocker: `> **Depends:** id:z0135 (stage1 builds the closure wrong)`. Free text is never a dependency, and "an identifier no task carries" (§5.1) means an `id:` word that names no task, never a stray word. A condition that is not a task — "a release cycle with no disagreement" — may be written there for people, but no tool checks it; a blocker that must stop selection has to be a task with an identifier.

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

#### 4.4.5 Lazy-Continuation Boundary Enforcement

Top-level prose MUST NOT directly follow a task line, or the last line of its payload block, without at least one intervening blank line (Rule V13).

Under CommonMark rules, a paragraph line starting at column 0 that directly follows a paragraph inside a blockquote or list item, with no intervening blank line, is a lazy continuation line: it is absorbed into that paragraph. Directly beneath a task line it would become part of the task's summary; directly beneath a payload it would become part of the payload. Requiring a blank line before any top-level prose that follows a task guarantees that the prose always renders as an independent paragraph. The rule is deliberately stricter than CommonMark — it also covers prose that would *not* be absorbed, such as a line following a closed code fence — so that the check needs no knowledge of what the previous line's block was.

## 5. Task Lifecycle

This section describes the working practices Taskmark is shaped around and the operations tooling is expected to provide. **None of it is required.** Taskmark defines a file format, not a methodology: any workflow that keeps the files conforming to §§2–4 is valid, whether or not it uses sprints, sweeps, or archives at all. A user who keeps a single `active.tm.md` by hand and never sweeps or archives anything is using Taskmark correctly.

### 5.1 Session Start

At the beginning of a working session, read `.tasks/active.tm.md` and choose the first pending (`- [ ]`) task that has no unmet dependencies and suits the session. Consult `future.tm.md` when context on upcoming work is needed. The reference CLI's `tm next` makes this selection.

* **Position is the order of work.** Tasks are taken from the top of the file down, across headings. To change the order, move the task.
* **A priority flag is the exception.** A task with a priority flag (§4.3.1) is taken ahead of position: flagged tasks come before unflagged ones, `A` first, and position decides among tasks with the same flag.
* **Dependencies.** A task's `Depends` field (§4.4.2) names the tasks that must be completed before it can start. A dependency is unmet until the task it names is `- [x]`, in any task file, the archive included. A reference to an identifier that no task carries is also unmet — it is most likely a typing error — and tools SHOULD report it.
* **State the order once.** Order SHOULD NOT be restated in prose, in numbered lists, or in payload notes ("before X", "after Y"): the copies go stale and then contradict the file. `Depends` is for a hard blocker only — a task that cannot be started — not for a preferred sequence, which position already expresses.
* **Suiting the session.** Tags (§4.3.2) narrow the choice: a session working in one context takes the first task that carries its tag (`tm next @backend`). The same mechanism covers work that is finished but awaiting review, with no third task state: the author adds `@review` to the task line and leaves the task pending; an implementing session passes over it (`tm next --not @review`), a reviewing session selects it (`tm list @review`), and the reviewer completes it. A review that finds the work incomplete sends it back the same way: the reviewer records the finding in the payload and removes `@review`, and the task rejoins the queue at its position.
* **Headings do not gate selection.** Selection reads the whole file, so once the tasks under the first heading are done or blocked, the next one comes from the heading below. A project that wants later work held back until someone promotes it keeps that work in `future.tm.md` (§5.4), which selection never reads.
* **Placing a new task.** Since position is the order, a new task goes where it should be done: immediately before the first task it blocks, directly after the task it follows up, otherwise at the end of the queue — or in `future.tm.md` when it is not scheduled soon. Adding a task SHOULD NOT reorder the tasks already there; who may reorder is the project's decision, and a project with several authors does well to name one. The reference CLI places a task this way with `tm add --before <task>` or `--after <task>`, and `tm move` takes the same options.

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

The `Completed` field MUST carry an ISO date. The short git hash of the implementing commit (`git:<sha>`, 7–40 hex characters) MUST be present whenever the task involved a commit, so the archive stays auditable against history, and MUST be omitted for a task completed outside of coding. When using an orphan branch topology (§10.2), this hash references the commit on the primary code branch, establishing cross-branch auditability (§10.3).

Steps 2 and 3 are a single mechanical edit, and are best left to a tool (the reference CLI's `tm done`) so that the token, indent, and field placement come out right every time.

A recorded hash names the commit as it stood when the task was stamped. Rewriting history afterward — squash, amend, rebase — can leave it pointing at nothing. The format cannot prevent this; §10.3 describes how to stamp so that it does not happen, and what to do after a branch is squashed. The reference CLI's `tm check-shas` reports a citation that no longer names a commit, and `tm remap` repairs one.

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

Swept tasks are bucketed in `completed.tm.md` (§6.3) under a section named for the month of the sweep, `## YYYY-MM`. A tool MAY let the user name the bucket instead — `## Sprint <id>` for a project that works in sprints. The bucket records when work left the active file; each task's own `Completed` date remains the authority for when it was done, and is what archive aging uses (§5.5).

Original headings are **not** copied into `completed.tm.md`. Active work is grouped topically for planning; completed work is grouped chronologically for audit. Copying topical headings into the archive would scatter fragmentary duplicates of them throughout it. A task that becomes unclear once separated from its heading is a task whose description was leaning on that heading — `+project` and `@context` tags exist to make a task self-standing.

Headings and top-level prose in `active.tm.md` are never swept and are never automatically deleted, including when every task beneath them has been swept away. In keeping with the minimalist goals of the format, removing a heading left empty by a sweep is left to the user, if it is wanted at all.

### 5.4 Sprint Boundaries

Taskmark has no rotation operation: a sprint, milestone, or other cycle is a workflow convention, not something the format records. At a boundary — or whenever `active.tm.md` grows unwieldy — a project that works in cycles typically:

1. Sweeps (§5.3), optionally bucketing the swept tasks under the cycle's name (`## Sprint <id>`).
2. Edits any cycle headings in `active.tm.md` by hand.
3. Chooses what to bring in from `future.tm.md`.

**`future.tm.md` is never changed automatically.** Moving a task from planned work into active work is always a deliberate user decision — it is what planning *is* — and no tool selects, promotes, or moves those tasks on the user's behalf. A tool MAY offer to open `future.tm.md`, or to move one named task the user has chosen, but it MUST NOT promote tasks by any automatic rule.

A section in `completed.tm.md` carries no date of its own. Its age derives from the most recent `Completed` date among its own tasks (§5.5). One date convention per task is sufficient; a section-level timestamp would record only when a section happened to move, which says nothing about the work.

### 5.5 Archive Aging

A section ages out of `completed.tm.md` when it is **both** outside the two most recent sections **and** its most recent `Completed` date is more than fourteen days old. With monthly sections this keeps the current and previous month in `completed.tm.md`, so the file stays short. Both thresholds are tool defaults and MAY be configurable; the rule that age derives from the tasks' own `Completed` stamps is normative.

An aged-out section is moved **verbatim** — its heading and every task and payload line unchanged — into `archive/<YYYY>/<YYYY-MM>.tm.md`, where the year and month come from that same most recent `Completed` date. Multiple sections may land in one monthly file. Like `completed.tm.md`, an archive file is kept newest first: arriving sections are inserted directly beneath its title, and sections already there are carried over unchanged.

## 6. File Conventions

### 6.1 `active.tm.md` — Current Sprint

Normally one sprint under a single `# Current Sprint` heading. Keep it short enough that its task lines — what `tm list` prints — fit on one screen. That is a limit on the number of tasks, not on their payloads: a task's checks, findings, and review notes belong with it and may run as long as the work needs. Work that is not scheduled soon belongs in `future.tm.md`, not at the bottom of this file.

```markdown
# Current Sprint

Bootstrap work is blocked on the vendor contract; start with the socket path.

- [ ] (A) +net First task
    - Sub-bullet with detail

- [ ] +cli Second task
    > **Context:** Why this matters.
```

When concurrent sprints are in flight, separate them with H2 headings:

```markdown
# Active Sprints

## Sprint Name A

- [ ] Task belonging to sprint A

## Sprint Name B

- [ ] Task belonging to sprint B
```

Headings in this file divide work by *when* it is done — this sprint, the next. Any other axis — code branch, component, owner — is better carried by a tag (§4.3.2): `@context` for where or by whom the work is done, `+project` for what it belongs to. Position is the order of work across headings (§5.1), so headings used for a second axis turn the heading order into an accidental priority: a five-minute task under a later heading cannot be placed ahead of a long series under an earlier one.

### 6.2 `future.tm.md` — Planned Work

Groups planned tasks by theme using H2 headings. The `+tag` convention (§4.3.2) maps naturally onto section names.

Tasks leave this file only when the user moves them into `active.tm.md` (§5.4). Nothing in the format or the tooling promotes them automatically.

```markdown
# Planned Work

## Feature Area

- [ ] +feature Planned task with detail
    - Sub-point

## Another Area

- [ ] +other Another planned task
```

### 6.3 `completed.tm.md` — Reverse-Chronological Archive

Both sections and tasks within each section are maintained in strict **reverse chronological order** (newest work first). On each sweep, tasks are bucketed under chronological headings (`## YYYY-MM` or `## Sprint <id>`).

The **document title** is the first heading in the file when it is level 1 (e.g. `# Completed Archive`). The **top section** is the first heading beneath the title — or, in a file with no title, the first heading of all.

* If the top section is the matching section, newly completed tasks are **prepended** into it, directly beneath its section heading.
* Otherwise a new section heading is created at the top: directly beneath the title, or above the first heading when there is no title, or after any preamble prose when the file has no headings at all.
* Older sections and tasks remain untouched below.
* Tasks moved by one sweep are ordered newest first by their own `Completed` dates; tasks with equal or no dates keep their order from the active file.

This guarantees that developers and AI coding agents inspect the latest accomplishments immediately without reading through an arbitrarily long file.

```markdown
# Completed Archive

## 2026-11

- [x] (A) +api Most recently completed task
    > **Completed:** 2026-11-08 git:abc1234

- [x] Earlier completed task in same month
    > **Completed:** 2026-11-02 git:789abcd

## 2026-10

- [x] +cli Older completed task
    > **Completed:** 2026-10-15 git:def5678
```

The heading text `# Completed Archive` is conventional, not load-bearing (§4.2): a tool identifies the title by its position and level, whatever it says.

Two branches that both sweep will conflict here, since both insert at the same anchor. The conflict is always safe to resolve by keeping both sides: sections and tasks are independent, and only their order is at stake.

### 6.4 `archive/<YYYY>/<YYYY-MM>.tm.md` — Aged Sections

Tool-managed, never hand-authored. Sections arrive here by the aging rule in §5.5, each keeping its original heading and content verbatim, and are kept newest first beneath the file's title.

The filename repeats the year — `archive/2026/2026-01.tm.md` — so that every archive file identifies its own period without reference to the directory holding it. A file copied, attached, or opened on its own is still unambiguous.

```markdown
# Archived Tasks — 2026-01

## 2026-01

- [x] +net Task completed the prior January
    > **Completed:** 2026-01-15 git:9f1e2a3
```

## 7. Parsing Model

Because headings, task tokens, and the payload indent are each identifiable from a line's own leading characters, a conforming reader is a single pass with one variable of state — the current heading, per §4.2. No abstract syntax tree is required.

```lua
-- Schematic Taskmark reader. One pass, one variable of state.
local heading = nil

for line in io.lines(".tasks/active.tm.md") do
    if line:match("^#+ ") then
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

## 8. Editor Integration

Taskmark's grammar is fixed enough that syntax highlighting, folding, and completion can be implemented with regex-based rules or a small Tree-sitter grammar. No language server is needed, and none should be built.

A conforming editor integration SHOULD name its filetype `taskmark` and SHOULD activate on any of the following:

1. **Extension glob** — `*.tm.md`. This is the primary trigger (§2.1).
2. **Path glob** — files inside a configured tasks directory, `*/.tasks/*` by default (§9), which catches a project that has renamed its task files.

### 8.1 Authoring Aids

Most of the friction in writing Taskmark by hand comes from defaults an editor applies to ordinary Markdown. An integration SHOULD, for filetype `taskmark`:

* **Continue a task into its payload at four spaces.** No editor's default list continuation produces this, and it is needed on every payload line, which makes it the single highest-value thing a plugin can do.
* **Disable automatic hard wrapping.** Taskmark has no line-length limit (§2.3), and an editor that wraps a long `> **Key:** value` line silently produces an invalid document (§4.4.2) from a setting the user has forgotten is on.
* **Expand tabs on insert outside fenced code blocks**, and leave fence content untouched (§4.4.3).
* **Fold payload blocks and completed sections**, both of which are identifiable from indentation and the task token alone.

Moving material in and out of a payload — a stack trace, a diff, a block of source — is the one case an editor cannot help with generically, since the text carries its own indentation and must gain or shed the payload prefix without losing it. A tool SHOULD therefore provide a **payload indent filter and its inverse**, both plain stdin-to-stdout filters:

* **Indent** prefixes every non-blank line with the four-space payload indent and emits blank lines as genuinely empty, so no line is left holding four spaces of trailing whitespace (§2.3). It changes nothing else. It MAY wrap the result in a fence with a given info string.
* **Dedent** removes exactly four leading spaces from each line and changes nothing else. It MUST fail rather than truncate when a non-blank line does not carry the full four-space prefix — that is the case where the selection has picked up a task line or top-level prose, and silently eating characters from it is the one way this operation can destroy data. It MAY additionally drop the opening and closing fence markers, which is usually what is wanted when lifting a code block back out to a file or a compiler.

The two MUST round-trip: dedent after indent returns the input byte for byte, for any input whatsoever. That is what gives §4.4.3's verbatim guarantee something to stand on. Whitespace-sensitive material — Makefile recipes, tab-indented Go, a diff whose leading spaces are significant — goes into a payload and comes back out unchanged, rather than being merely *stored* faithfully and then mangled on the way out.

**Known erratum:** "for any input whatsoever" overstates it for a line-oriented filter. Input with no trailing newline gains one on the round trip, since a trailing newline is not itself a line these filters read or emit. This is a gap in the spec's wording, not license to accept the mismatch silently; an implementation that leaves it unfixed MUST say so.

Keeping these as filters rather than editor features is what makes them universal: they compose with the shell (`tm indent < trace.txt`, `xclip -o | tm indent`, `tm dedent > patch.diff`) and, more usefully, with any editor that can pipe a region through an external command, which covers essentially all of them. No plugin is required to get the behavior, and neither filter needs a parser or any state.

### 8.2 Modelines

For a file opened outside any of the triggers above, a standard modeline in a trailing HTML comment forces the filetype explicitly and is invisible in rendered Markdown:

```markdown
<!-- vim: set ft=taskmark : -->
```

An editor with no Taskmark plugin renders every one of these files as ordinary Markdown with interactive checkboxes. Nothing about the format depends on tooling being installed.

## 9. Configuration

By default a Taskmark tool operates entirely on the conventional paths above; no configuration file is required and initialization never creates one. Configuration exists so a project or a user can move those paths, and it does nothing else (§9.3).

### 9.1 Files

Configuration uses a flat `key: value` subset, read from two locations:

* **Global** — `$XDG_CONFIG_HOME/taskmark/config`, defaulting to `~/.config/taskmark/config` when `XDG_CONFIG_HOME` is unset.
* **Local** — `.taskmarkrc` in the current working directory or discovered by searching upward to the enclosing Git repository or worktree root (§9.2).

```text
# paths for this project
tasks_dir: .tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

Blank lines and comment lines — those whose first non-space character is `#` — are ignored. Every value is a literal scalar string.

All keys are optional in both files. An absent key, an absent file, or a line a reader cannot parse falls back silently to the next source below, so a project with no configuration behaves exactly as one with an empty file.

### 9.2 Resolution Order

Resolution is **per key**, not per file: a local file that sets only `tasks_dir` leaves every other key to the global file and the built-in defaults. For each path a tool needs, highest priority first:

1. **Explicit command-line arguments** — a `--tasks-dir DIR` option, or a file path passed positionally to a subcommand that accepts one. These bypass both configuration files for the paths they name.
2. **Local `.taskmarkrc`** — in the current working directory, or discovered by searching upward from the current working directory, stopping at the enclosing Git repository or worktree boundary. When discovered in an ancestor directory, relative paths in the configuration file are resolved relative to the directory containing `.taskmarkrc`.
3. **Global configuration file.**
4. **Built-in defaults** — the conventional paths used throughout this specification. Inside a Git repository or worktree, unconfigured paths resolve relative to the repository root (§10).

**Legacy task directory.** Before SPEC-TASKMARK-04 the default `tasks_dir` was `doc/tasks`. When no source above sets `tasks_dir`, `.tasks/` does not exist, and `doc/tasks/` does, a tool SHOULD resolve `tasks_dir` to `doc/tasks` so that an existing project keeps working unconfigured. Once `.tasks/` exists, or `tasks_dir` is set anywhere, the fallback never applies.

### 9.3 Scope

Configuration controls *where* a tool reads and writes the files this specification defines. It does not change file contents, task grammar, or any other rule in this document. `archive_dir` renames only the top-level folder; the `<YYYY>/<YYYY-MM>.tm.md` layout beneath it is fixed.

## 10. Isolation and Portability

Task data lives inside `.tasks/` relative to the repository root, so it travels with the repository through clones, containers, and sandboxes with no external path hierarchy, no global data store, and no network service. A project's tasks are as private as its source, and history for both is the same history.

### 10.1 In-Tree Placement

By default, `.tasks/` resides directly inside the repository tree on the primary branch. This is the simplest topology: every clone gets the complete task history, and commits to tasks share the branch timeline with code.

### 10.2 Orphan Git Branch Topology and Worktree Integration

Storing frequent task mutations directly on the primary code branch (`main`) adds commit noise and pull-request churn. To keep task history separate from code history while keeping the files on disk, a project MAY keep its task directory on an independent **orphan branch** (conventionally `tasks`) that is mounted at `.tasks/` as a Git worktree. Nothing about the file format changes; this is purely a storage arrangement.

Setting it up once, from the repository root (the reference CLI's `tm init --orphan` performs these steps):

```shell
echo "/.tasks/" >> .gitignore            # 1. hide the mount from the code branch
# 2. (only for a directory other than .tasks: echo "tasks_dir: DIR" >> .taskmarkrc)
git worktree add --orphan -b tasks .tasks   # 3. mount a new orphan branch (git >= 2.42)
# ...create the task files, then commit and publish the branch:
git -C .tasks add -A && git -C .tasks commit -m "Initialize task branch"
git -C .tasks push -u origin tasks
git add .gitignore && git commit -m "Track tasks on the tasks branch"
```

A worktree is local to one clone; cloning the repository fetches the `tasks` branch but does not mount it. Each collaborator mounts the *existing* branch, so that everyone shares one task history:

```shell
git fetch origin
git worktree add .tasks tasks    # creates a local `tasks` tracking origin/tasks
```

Starting a second orphan branch instead would give that collaborator an unrelated history that cannot be pushed without merging the two.

In this topology:

- **History isolation:** commits on `tasks` share no history with `main` or feature branches.
- **Clean code branches:** `git status` and pull-request diffs on code branches never show task edits, because `/.tasks/` is ignored there.
- **Independent synchronization:** task commits are made and pushed on their own schedule (`git -C .tasks commit` / `push`, or the reference CLI's `tm sync`), subject to the same git hooks as any other commit.

Search tools that honor `.gitignore` — `ripgrep` and the editors and AI coding agents built on it — skip `.tasks/` when searching the whole repository, although they still read or search it when given its path. Usually that is welcome, keeping historical task text out of code searches. A project that wants repository-wide searches to include its tasks can add a `.ignore` file containing `!/.tasks/`, which `ripgrep` honors and Git does not read. Pointing agents at the files directly — for example, a line in the repository's agent instructions naming `.tasks/active.tm.md` — works either way.

### 10.3 Cross-Branch Commit References (`git:<sha>`)

In an orphan worktree topology, task files live on the task branch while code changes are committed to code branches. The `Completed` field (§5.2) records the *code* commit that implemented the task (`git:<sha>`), never the task-branch commit that recorded the completion. Both branches share one object store, so the reference resolves in any clone that has fetched the code branch.

The recorded link runs from task to commit, and nothing in the format requires the reverse. To find the task behind a commit, search the task files for its hash — `rg <sha> .tasks/` — including `completed.tm.md` and `archive/`. A project that wants the reverse link as well MAY cite the task's identifier (§4.3.3) in the commit message — `Task: id:k7q2x` — which stays valid however the task's text is later edited. A tooling handle derived from the task's text does not, and SHOULD NOT be cited. A citation in a published commit can never be corrected, which is the strongest reason an identifier is never changed or reused.

A recorded hash can stop resolving if the commit it names is discarded. In particular, a hash taken from a feature branch that is later squash-merged or rebased names a commit that may never reach `main`, and is lost once that branch is deleted and garbage-collected. Stamp the hash of the commit as it lands on the long-lived branch, or update the stamp after merging. When a squash replaces commits whose hashes are already stamped, replace each old hash with its new one everywhere it is cited, in a task commit of its own that lists the old/new pairs, so the remapping is itself auditable. The reference CLI does the replacement with `tm remap OLD NEW [OLD NEW...]`, across every task file including the archive, and `tm check-shas --branch main` confirms afterward that every citation names a commit on the long-lived branch.
