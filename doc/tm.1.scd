tm(1)

# NAME
tm - universal taskmark utility

# SYNOPSIS
*tm* <command> [options]

# DESCRIPTION
*tm* is the command-line interface for SPEC-TASKMARK-04 taskmark files. It
provides subcommands to sweep completed tasks between task documents,
archive aged-out sections, validate files for spec compliance, and
filter arbitrary text into and out of a payload block. The specification it
implements is documented in _doc/taskmark_spec.md_.

Unless a path is given, *tm* operates on the _.tasks_ directory relative to
the current working directory (the layout described by the spec).

# COMMANDS
*init*
	Bootstrap _.tasks_ with starter _active.tm.md_, _future.tm.md_, and
	_completed.tm.md_ files. Never overwrites a file that already exists.

*sweep*
	Move every `- [x]` task and its payload out of _active.tm.md_ and into
	_completed.tm.md_, bucketed under a "## YYYY-MM" section for the month
	of the sweep, or "## Sprint _LABEL_" with *--sprint*. Tasks within a
	section and sections within the file are kept newest first. Headings
	and top-level prose in _active.tm.md_ are never swept, even when every
	task beneath them is done. _future.tm.md_ is never read or written.

*archive*
	Move sections aged out of _completed.tm.md_ into
	_.tasks/archive/<YYYY>/<YYYY-MM>.tm.md_, grouped by the month of
	each section's most recent *Completed* task and inserted newest first
	beneath the archive file's title. A section is retained if it is among
	the 2 newest or its most recent *Completed* task is dated within the
	last 14 days.

*validate* [--fix] [file...]
	Validate taskmark file(s) for SPEC-TASKMARK-04 compliance. If no _file_
	is given, defaults to the configured active file. If *--fix* is given,
	automatically repairs common formatting errors (over-indented bullet
	continuations and sub-lists, wrapped labeled fields, missing blank lines
	after labeled fields, prose directly beneath a task or payload, hard
	tabs, leading frontmatter blocks from pre-0.4 files, and top-level dash
	bullets converted to '\*'). The file's newline style is preserved. Exits 0 on success (or successful
	repair), 1 on validation failure or file error.

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
*--sprint* _LABEL_
	With *sweep*: bucket the swept tasks under "## Sprint _LABEL_" instead
	of the current month.

*--dry-run*
	Report what would move and change nothing. Applies to *sweep* and
	*archive*.

*--tasks-dir* _DIR_
	Directory holding the task files. Defaults to _./.tasks_, or the
	*tasks_dir* set in _.taskmarkrc_ (see CONFIGURATION).

*-h*, *--help*
	Show help for the command.

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
	Transient lock directory held by *sweep*, *archive*, and
	*validate --fix* for the duration of their read-modify-write, so
	concurrent *tm* runs wait for each other instead of losing updates.
	A stale lock left by a killed process may be removed by hand.

# CONFIGURATION
Configuration uses a flat `key: value` format, read from two locations, each
optional:

- *Global* — _\$XDG_CONFIG_HOME/taskmark/config_, falling back to
  _~/.config/taskmark/config_ when unset.
- *Local* — _.taskmarkrc_ in the directory *tm* is invoked from.

```
tasks_dir: .tasks
active_file: active.tm.md
future_file: future.tm.md
completed_file: completed.tm.md
archive_dir: archive
```

Resolution is per key, highest priority first: an explicit command-line
option, the local file, the global file, then the built-in default shown
above. When *tasks_dir* is not set anywhere and _./.tasks_ does not
exist but _./doc/tasks_ (the pre-0.4 default) does, _./doc/tasks_ is used.
An absent file, an absent key, or an unparseable line falls back
silently to the next source. See _doc/taskmark_spec.md_ §9 for the full
resolution order.

# SEE ALSO
_doc/taskmark_spec.md_
	The SPEC-TASKMARK-04 specification implemented by this tool.
