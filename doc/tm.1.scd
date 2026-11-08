tm(1)

# NAME
tm - universal taskmark utility

# SYNOPSIS
*tm* <command> [options]

# DESCRIPTION
*tm* is the command-line interface for SPEC-TASKMARK-03 taskmark files. It
provides subcommands to sweep completed tasks between task documents, rotate
sprints, archive aged-out sections, validate files for spec compliance, and
filter arbitrary text into and out of a payload block. The specification it
implements is documented in _doc/taskmark_spec.md_.

Unless a path is given, *tm* operates on the _doc/tasks_ directory relative to
the current working directory (the layout described by the spec).

# COMMANDS
*init*
	Bootstrap _doc/tasks_ with starter _active.tm.md_, _future.tm.md_, and
	_completed.tm.md_ files. Never overwrites a file that already exists.

*sweep*
	Move every `- [x]` task and its payload out of _active.tm.md_ and into
	_completed.tm.md_, under a "## Sprint <sprint>" heading matching
	_active.tm.md_'s current *sprint* field (appending into that section if
	it is already the most recent one, rather than duplicating it).
	Headings and top-level prose are never swept, even when every task
	beneath them is done.

*rotate*
	A sweep, then update *sprint* and *date* in _active.tm.md_'s
	frontmatter and *date* in _completed.tm.md_'s. Requires *--sprint*.
	_future.tm.md_ is never read or written, and no task is ever promoted
	automatically.

*archive*
	Move sections aged out of _completed.tm.md_ into
	_doc/tasks/archive/<YYYY>/<YYYY-MM>.tm.md_, grouped by the month of
	each section's most recent *Completed* task. A section is retained if
	it is among the 10 newest or its most recent *Completed* task is dated
	within the last 14 days.

*validate* [--fix] [file...]
	Validate taskmark file(s) for SPEC-TASKMARK-03 compliance. If no _file_
	is given, defaults to the configured active file. If *--fix* is given,
	automatically repairs common formatting errors (over-indented bullet
	continuations and sub-lists, wrapped labeled fields, missing blank lines
	after labeled fields, hard tabs, and top-level dash bullets converted
	to '\*'). Exits 0 on success (or successful repair), 1 on validation
	failure or file error.

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
*--sprint* _VALUE_
	New sprint identifier to stamp on _active.tm.md_. Required with
	*rotate*.

*--dry-run*
	Report what would move and change nothing. Applies to *sweep*,
	*rotate*, and *archive*.

*--tasks-dir* _DIR_
	Directory holding the task files. Defaults to _./doc/tasks_, or the
	*tasks_dir* set in _.taskmarkrc_ (see CONFIGURATION).

*-h*, *--help*
	Show help for the command.

# FILES
_doc/tasks/active.tm.md_
	The current sprint.

_doc/tasks/future.tm.md_
	Planned work not yet scheduled to a sprint.

_doc/tasks/completed.tm.md_
	Append-only archive of completed sprints, newest first.

_doc/tasks/archive/<YYYY>/<YYYY-MM>.tm.md_
	Sections aged out of _completed.tm.md_. Tool-managed; never
	hand-authored, and never rewritten once written.

_<tasks-dir>/.tm.lock_
	Transient lock directory held by *sweep*, *rotate*, *archive*, and
	*validate --fix* for the duration of their read-modify-write, so
	concurrent *tm* runs wait for each other instead of losing updates.
	A stale lock left by a killed process may be removed by hand.

# CONFIGURATION
Configuration uses the same flat `key: value` subset as frontmatter, read
from two locations, each optional:

- *Global* — _\$XDG_CONFIG_HOME/taskmark/config_, falling back to
  _~/.config/taskmark/config_ when unset.
- *Local* — _.taskmarkrc_ in the directory *tm* is invoked from.

```
tasks_dir: doc/tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

Resolution is per key, highest priority first: an explicit command-line
option, the local file, the global file, then the built-in default shown
above. An absent file, an absent key, or an unparseable line falls back
silently to the next source. See _doc/taskmark_spec.md_ §10 for the full
resolution order and the additional hub-related keys.

# SEE ALSO
_doc/taskmark_spec.md_
	The SPEC-TASKMARK-03 specification implemented by this tool.
