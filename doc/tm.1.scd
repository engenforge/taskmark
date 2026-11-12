tm(1)

# NAME
tm - universal taskmark utility

# SYNOPSIS
*tm* <command> [options]

# DESCRIPTION
*tm* is the command-line interface for SPEC-TASKMARK-05 taskmark files. It
provides subcommands for atomic task mutations, compact task listings
addressed by task identifier, sweeping completed tasks between task documents in
strict reverse chronological order, archiving aged-out sections, validating
files for spec compliance, and filtering arbitrary text into and out of a
payload block. The specification it implements is documented in
_doc/taskmark_spec.md_.

Unless a path is given, *tm* operates on the _.tasks_ directory relative to
the current working directory (the layout described by the spec).

# COMMANDS
*init* [--orphan [_BRANCH_]] [--tasks-dir _DIR_]
	Bootstrap _.tasks_ with starter _active.tm.md_, _future.tm.md_, and
	_completed.tm.md_ files. Never overwrites a file that already exists.
	With *--orphan*, keeps the tasks directory on its own git branch,
	mounted as a worktree (see *--orphan*).

*sync* [-m _MSG_] [--tasks-dir _DIR_] [-p|--push]
	Stage and commit every change in the tasks directory (default message
	"tasks: sync (<timestamp>)"), and with *--push* push it. The tasks
	directory must be the top level of its own git work tree -- normally
	the worktree made by *init --orphan* -- so nothing outside it can be
	staged; a plain directory inside a larger repository is refused. Git
	hooks run as for any commit, and git's own messages are shown when a
	commit or push fails.

*list* [--pending|--all] [--not _TAG_]... [_TAG_...] [--tasks-dir _DIR_] [_file_...]
	Print one line per task, its handle and summary, e.g.
	"[k7q2x] (A) Task text id:k7q2x", without payload blocks, to keep
	listings short for humans and AI agents alike. By default, lists pending
	tasks from the active task document. With *--all*, lists both pending
	and completed tasks (completed tasks marked `[x]`). An argument starting
	with '+' or '@' is a tag: only tasks carrying every _TAG_ given, as a
	whole word anywhere on the task line, are listed, and *--not* _TAG_
	leaves out tasks carrying it. Given several files, each listing
	is headed `== <file>`. A file with nothing to list prints nothing on
	standard output and a short note on standard error. A missing file is
	an error.

*next* [--not _TAG_]... [_TAG_...] [--file _FILE_] [--tasks-dir _DIR_]
	Print the task to start, in the format of *list*: among the pending
	tasks of _active.tm.md_ (or *--file*) that match the tag filters and
	have no unmet dependency, the one with the highest priority flag, or
	the first in file order when none is flagged. A dependency (see TASK
	IDENTIFIERS) is met once the task it names is completed, in any task
	file. A dependency naming no task counts as unmet and is reported on
	standard error. When no task is ready, prints nothing on standard
	output, a note on standard error, and exits 0.

*add* _<task-text>_ [-p|--priority _PRI_] [--section _SECTION_ | --before _TASK_ | --after _TASK_] [--file _FILE_] [--tasks-dir _DIR_]
	Add a pending task at the end of the named section's own content
	(before its first subheading), or of the first heading's when no
	*--section* is given; or, with *--before* or *--after*, directly above
	the named task or directly below its payload, under whatever heading
	that task sits. An unknown section or a missing file is an error;
	no file is ever created. *-p A* adds the `(A)` priority flag. The task
	is stamped with a new identifier (see TASK IDENTIFIERS) unless its text
	already carries one, such as one carried over from an existing
	numbering scheme (`tm add "Fix the parser id:z0114"`); a supplied
	identifier that already occurs in any task file is an error.

*id* [--tasks-dir _DIR_] [_file_...]
	Stamp a new identifier on every pending task that lacks one, in
	_active.tm.md_ and _future.tm.md_ or in the files given. Completed
	tasks are never changed. Also reports, on standard error, any
	identifier carried by more than one task in any task file.

*done* _<hash-or-pattern>_ [--git [_REV_]] [--file _FILE_] [--tasks-dir _DIR_]
	Find a pending task in _active.tm.md_ (or *--file*) by handle or
	substring (see TASK HANDLES), mark it `- [x]` in place, and stamp a
	Completed field with the local date into the leading run of its
	labeled fields, adding `git:<sha>` with *--git*. Only pending tasks are
	candidates; a match that is already completed is reported as such.

*move* _<hash-or-pattern>_ [--from _FILE_] [--to _FILE_] [--section _SECTION_ | --before _TASK_ | --after _TASK_] [--tasks-dir _DIR_]
	Move a task and its payload from one file to another (by default from
	_future.tm.md_ to _active.tm.md_), or to another place in the same
	file, placed as for *add*; with *--before* or *--after* in one file,
	this reorders the queue. The destination is written before the task
	is removed from the source, so an interrupted move leaves a duplicate,
	never a loss. The destination must exist.

*sweep*
	Move every `- [x]` task and its payload out of _active.tm.md_ and into
	_completed.tm.md_, bucketed under a "## YYYY-MM" section for the month
	of the sweep, or "## Sprint _LABEL_" with *--sprint*. Tasks within a
	section and sections within the file are kept in strict reverse chronological
	order (newest completed first). Headings and top-level prose in _active.tm.md_
	are never swept, even when every task beneath them is done. _future.tm.md_
	is never read or written.

*archive*
	Move sections aged out of _completed.tm.md_ into
	_.tasks/archive/<YYYY>/<YYYY-MM>.tm.md_, grouped by the month of
	each section's most recent *Completed* task and inserted newest first
	beneath the archive file's title. A section is retained if it is among
	the 2 newest or its most recent *Completed* task is dated within the
	last 14 days.

*check-shas* [--branch _REF_] [--tasks-dir _DIR_]
	Report each `git:<sha>` citation in any task file, the archive
	included, that does not name a commit in the repository holding the
	tasks directory, as _file_:_line_: git:_sha_ _reason_. With *--branch*,
	also report commits not reachable from _REF_, such as the commits of a
	feature branch that was squash-merged. Exits 1 when it reports
	anything.

*remap* _OLD_ _NEW_ [_OLD_ _NEW_...] [--tasks-dir _DIR_]
	Replace every citation of commit _OLD_ -- any abbreviation of it, such
	as `git:a1b2c3d` for a full _OLD_ -- with `git:`_NEW_, in every task
	file, the archive and completed tasks included. Each _NEW_ must name a
	commit. Prints, per pair, how many citations changed in how many
	files, which can go in the message of the task commit that records the
	remapping.

*validate* [--fix] [file...]
	Validate taskmark file(s) for SPEC-TASKMARK-05 compliance. If no _file_
	is given, defaults to the configured active file. If *--fix* is given,
	automatically repairs common formatting errors (over-indented bullet
	continuations and sub-lists, wrapped labeled fields, missing blank lines
	after labeled fields, prose directly beneath a task or payload, hard
	tabs, leading frontmatter blocks from pre-0.4 files, and top-level dash
	bullets converted to '\*'). The file's newline style is preserved. Exits 0 on success (or successful
	repair), 1 on validation failure or file error.

	Beyond the rules of the specification, prints non-fatal `[WARN]` lines
	that never change the exit status: a *Created*, *Due*, or *Completed*
	field whose value is not the registered date format; a `\*\*Key:\*\*`
	inside a field's value, which is read as text and is usually a second
	field written on the same line; and an identifier carried by two tasks
	among the files given. In a completed task only the *Completed* field
	is checked: the rest of its text is a record. Duplicate identifiers are
	looked for only among the files given; *id* checks every task file. Output is coloured only when standard output is
	a terminal and the *NO_COLOR* environment variable is unset or empty.

*indent* [info]
	Read stdin, prefix every non-blank line with the four-space payload
	indent, and write the result to stdout. Blank lines are emitted
	genuinely empty. _info_, if given, wraps the result in a fenced code
	block carrying that info string.

*dedent* [--fence]
	Read stdin, remove exactly four leading spaces from every non-blank
	line, and write the result to stdout. Exits non-zero rather than
	truncate a line that lacks the full four-space prefix. *--fence* also
	drops the first and last line, for lifting a fenced block back out.

*help*
	Show a short usage summary.

*version*
	Print the version and exit.

# OPTIONS
*--pending*
	With *list*: output only pending tasks (the default).

*--all*
	With *list*: output both pending and completed tasks. Completed tasks are
	marked with `[x]`.

*--not* _TAG_
	With *list* and *next*: leave out tasks whose line carries _TAG_
	(e.g. `--not @review`). May be repeated.

*-p*, *--priority* _PRI_
	With *add*: assign a priority flag `(A)`-`(Z)` to the task.

*--section* _SECTION_
	With *add* and *move*: heading (matched case-insensitively) whose own
	content the task is appended to. Must exist.

*--file* _FILE_
	Target file to operate on. Defaults to the configured active file.

*--before* _TASK_, *--after* _TASK_
	With *add* and *move*: place the task directly above _TASK_, or directly
	below _TASK_'s payload. _TASK_ is a handle or pattern, resolved in the
	destination file as for *done*. Not combined with *--section*.

*--branch* _REF_
	With *check-shas*: also report citations of commits not reachable
	from _REF_.

*--from* _FILE_
	With *move*: source file to move the task from (defaults to _future.tm.md_).

*--to* _FILE_
	With *move*: destination file to move the task to (defaults to _active.tm.md_).

*--git* [_REV_]
	With *done*: record the short SHA of _REV_ (default *HEAD*) in the
	Completed field, e.g. `> **Completed:** YYYY-MM-DD git:<sha>`. _REV_
	must name a commit in the current repository. The word after *--git* is
	taken as _REV_ only when the command would otherwise have two
	arguments, so `tm done --git abc1234 parser` and `tm done parser --git`
	both work; `--git=`_REV_ is always unambiguous.

*--sprint* _LABEL_
	With *sweep*: bucket the swept tasks under "## Sprint _LABEL_" instead
	of the current month.

*--dry-run*
	Report what would move and change nothing. Applies to *sweep* and
	*archive*.

*--tasks-dir* _DIR_
	Directory holding the task files. Defaults to _./.tasks_, or the
	*tasks_dir* set in _.taskmarkrc_ (see CONFIGURATION).

*--orphan* [_BRANCH_]
	With *init*, run from the repository root: mount branch _BRANCH_
	(default _tasks_) at the tasks directory as a git worktree, add the
	directory to _.gitignore_ (and, when it is not _.tasks_, set *tasks_dir* in
	_.taskmarkrc_). An existing local branch is mounted as is; a branch
	already fetched from a remote is checked out tracking it, so a
	collaborator joins the shared
	task history; otherwise a new orphan branch is created with only the
	starter files, committed with hooks running. Works with any git that has
	*git worktree*. Refuses an existing directory that is not a worktree.
	The changed _.gitignore_ (and _.taskmarkrc_, if written) are left for you to
	commit.

*-m*, *--message* _MSG_
	With *sync*: commit message, passed to git verbatim.

*-p*, *--push*
	With *sync*: push after committing. The first push of a new branch sets
	its upstream to _origin_, or to the only remote.

*-h*, *--help*
	Show help for the command.

# TASK IDENTIFIERS
A task may carry an identifier: a word on its task line made of `id:` and
four or more lowercase letters and digits, e.g. `id:k7q2x`. It never
changes and is never reused, and it stays with the task when the task is
edited, moved, completed, swept, and archived, so it can be cited from
another task, a commit message, or a review note.

*add* and *id* assign identifiers. Each is five characters drawn at random
from _/dev/urandom_ (digits and lowercase letters without i, l, o, and u),
and is redrawn if it already occurs anywhere in _active.tm.md_,
_future.tm.md_, _completed.tm.md_, or the archive. There is no counter and
no index file. An identifier written by hand, or carried over from an
existing scheme (`Z-0114` as `id:z0114`), is equally valid.

A task names the tasks that must be completed before it can start in a
*Depends* field, which *next* reads:

```
- [ ] +api Add rate limiting id:k7q2x
    > **Depends:** id:m3x8a
```

Copying a task copies its identifier. *id* and *validate* warn when two
tasks carry the same one; give one of them a new identifier by hand.

# TASK HANDLES
*list* shows a _handle_ for each task, e.g. `[k7q2x]`. It is the task's
identifier when the task has one that no other task of the file shares.
Otherwise *tm* derives a deterministic 8-hex-digit hash from the task's
summary (the task line minus its checkbox and outer whitespace, so it
survives *tm done*) and shows its shortest prefix of at least 4 digits that
is unique within the file, e.g. `[f4a1]`. A hash handle is never written to
a file, and editing the task's text changes it.

*done* and *move* accept:
- An identifier, with or without its `id:` prefix.
- A hash handle, or any longer prefix of the same hash, with or without
  brackets. A prefix shared by several tasks is rejected, listing each
  candidate with its own unique handle.
- Otherwise, a case-insensitive substring of the task summary. A substring
  matching several tasks is likewise rejected with the candidates listed.

Two tasks with identical summaries share a hash; make their text differ to
address them separately.

For *add*, *done*, *move*, *list*, and *next*, `--` ends the options, so task text or
a pattern may begin with '-': `tm add -- "-v flag handling"`.

Task files may be symlinks: *tm* writes through a link to its target and
leaves the link in place.

# FILES
_.tasks/active.tm.md_
	The current sprint.

_.tasks/future.tm.md_
	Planned work not yet scheduled to a sprint.

_.tasks/completed.tm.md_
	Strict reverse-chronological archive of completed work, newest first.

_.tasks/archive/<YYYY>/<YYYY-MM>.tm.md_
	Sections aged out of _completed.tm.md_, newest first. Tool-managed;
	never hand-authored.

_<tasks-dir>/.tm.lock_
	Transient lock directory held by *add*, *id*, *done*, *move*, *remap*, *sweep*,
	*archive*, and *validate --fix* for the duration of their read-modify-write,
	so concurrent *tm* runs wait for each other instead of losing updates.
	A stale lock left by a killed process may be removed by hand.

# CONFIGURATION
Configuration uses a flat `key: value` format, read from two locations, each
optional:

- *Global* — _\$XDG_CONFIG_HOME/taskmark/config_, falling back to
  _~/.config/taskmark/config_ when unset.
- *Local* — _.taskmarkrc_ in the current working directory or discovered
  by searching upward to the enclosing repository root.

```
tasks_dir: .tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

Resolution is per key, highest priority first: an explicit command-line
option, the local file, the global file, then the built-in default shown
above. When discovered in an ancestor directory, relative paths in
_.taskmarkrc_ are resolved relative to the directory containing it.
When *tasks_dir* is not set anywhere and _./.tasks_ does not
exist but _./doc/tasks_ (the pre-0.4 default) does, _./doc/tasks_ is used.
An absent file, an absent key, or an unparseable line falls back
silently to the next source. See _doc/taskmark_spec.md_ §9 for the full
resolution order.

# SEE ALSO
_doc/taskmark_spec.md_
	The SPEC-TASKMARK-05 specification implemented by this tool.
