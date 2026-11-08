.PHONY: all clean check test version man man-check check-scdoc-man help install install-bin install-man install-version uninstall check-modules dist dist-bin

TEST_RUNNER     = tests/test_runner.lua
TMVAL           = src/tmval.lua
FIXTURES        = tests/fixtures
META_TEST       = tests/tmmeta_test.lua
SCAN_TEST       = tests/tmscan_test.lua
SWEEP_TEST      = tests/tmsweep_test.lua
INIT_TEST       = tests/tminit_test.lua
CONFIG_TEST     = tests/tmconfig_test.lua
FILTER_TEST     = tests/tmfilter_test.lua
IO_TEST         = tests/tmio_test.lua
MUTATE_TEST     = tests/tmmutate_test.lua
COMMONMARK_TEST = tests/commonmark_test.lua

PREFIX   ?= /usr/local
DESTDIR  ?=
BINDIR   := $(DESTDIR)$(PREFIX)/bin
SHAREDIR := $(DESTDIR)$(PREFIX)/share/tm
DOCDIR   := $(DESTDIR)$(PREFIX)/share/doc/tm
MANDIR   := $(DESTDIR)$(PREFIX)/share/man/man1

MAN_SRC  = doc/tm.1.scd
MAN      = doc/tm.1
VERSION_FILE = VERSION

# Release artifacts. <ver> is the tag without its leading "v" when HEAD is
# tagged, otherwise the spec version and commit. Tarballs are
# taskmark-<ver>.tar.xz (source) and taskmark-<ver>-noarch.tar.xz (the installed
# files, which are architecture-independent: nothing is compiled), timestamped
# with the commit time so the same commit always produces byte-identical files.
TM_VERSION_BASE := $(shell cat $(VERSION_FILE) 2>/dev/null || echo 0.0.0)
VERSION         := $(TM_VERSION_BASE)

GIT_COMMIT      := $(shell git rev-parse --short=12 HEAD 2>/dev/null)
GIT_TAG         := $(shell git describe --tags --exact-match HEAD 2>/dev/null)
DIST_VERSION    := $(if $(GIT_TAG),$(patsubst v%,%,$(GIT_TAG)),$(VERSION)-g$(GIT_COMMIT))
DIST_NAME       := taskmark-$(DIST_VERSION)
DIST_BIN_NAME   ?= $(DIST_NAME)-noarch
DIST_DIR        := build/dist
DIST_STAGE      := build/dist-stage
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct HEAD 2>/dev/null)

# The installed VERSION carries a git descriptor (tag, commit count past it,
# and short hash) alongside the plain semantic version, baked in at install
# time so `tm version` can tell exactly which commit an installed copy is
# from -- since bumping VERSION_FILE by hand on every commit isn't realistic,
# and two installs both reporting "0.3.0" can otherwise be different builds.
# Silently falls back to the plain version outside a git checkout, or when
# git itself isn't available.
TM_GIT_DESC := $(shell git describe --tags --long --always --dirty 2>/dev/null)
ifneq ($(TM_GIT_DESC),)
TM_VERSION_FULL := $(TM_VERSION_BASE) ($(TM_GIT_DESC))
else
TM_VERSION_FULL := $(TM_VERSION_BASE)
endif

# Tool variables
LUA             ?= lua
INSTALL         ?= install
INSTALL_PROGRAM ?= $(INSTALL) -m 755
INSTALL_DATA    ?= $(INSTALL) -m 644
INSTALL_DIR     ?= $(INSTALL) -d -m 755
RM              ?= rm -f
RMDIR           ?= rmdir
TAR             ?= tar
XZ              ?= xz
SHA256SUM       ?= sha256sum
SCDOC           ?= scdoc
MIN_SCDOC_VERSION ?= 1.11.5

# Deterministic archive options (GNU tar; xz runs single-threaded so output is stable): sorted names, commit timestamp,
# numeric root ownership, and normalized permissions (no setuid or setgid bits).
REPRO_TAR        = $(TAR) --sort=name --format=gnu --mtime=@$(SOURCE_DATE_EPOCH) \
                   --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w,a-s'

# The Lua modules installed under $(SHAREDIR); src/tm (the dispatcher) is
# installed separately, to $(BINDIR).
MODULES = tmmeta.lua tmscan.lua tmconfig.lua tmval.lua tmsweep.lua tmsweep_core.lua tmfilter.lua tminit.lua tmio.lua tmmutate.lua

UNAME_S := $(shell uname -s)

# Guard against a src/*.lua module being require()'d but left out of MODULES
# -- such a module loads fine from the source tree (src/tm's package.path
# falls back to src/ when share/tm lacks tmsweep_core.lua) but is silently
# missing from `make install`, so the installed tm fails with "module 'x'
# not found" the moment the omitted module is required. Runs as part of
# `make test` so CI catches a forgotten module without needing a real
# install.
check-modules:
	@required=$$(grep -hoE 'require\("tm[A-Za-z_]+"\)' src/tm src/*.lua | sed -E 's/require\("(.*)"\)/\1/' | sort -u); \
	missing=0; \
	for m in $$required; do \
		if [ -f "src/$$m.lua" ]; then \
			case " $(MODULES) " in \
				*" $$m.lua "*) : ;; \
				*) echo "check-modules: src/$$m.lua is require()'d but missing from MODULES in Makefile" >&2; missing=1 ;; \
			esac; \
		fi; \
	done; \
	if [ $$missing -ne 0 ]; then exit 1; fi

# Lua C module (vendored cmark-lua + libcmark under vendor/cmark/), used only
# by the test-only CommonMark conformance oracle (tests/commonmark_test.lua)
# -- nothing at runtime loads it. cmark.so is ABI-specific to the Lua
# interpreter that loads it. Use pkg-config if available, falling back to
# -llua.
LUA_CFLAGS ?= $(shell pkg-config --cflags lua 2>/dev/null || pkg-config --cflags lua5.4 2>/dev/null || pkg-config --cflags lua-5.4 2>/dev/null || pkg-config --cflags lua5.3 2>/dev/null || pkg-config --cflags lua5.1 2>/dev/null || true)
LUA_LDLIBS ?= $(shell pkg-config --libs lua 2>/dev/null || pkg-config --libs lua5.4 2>/dev/null || pkg-config --libs lua-5.4 2>/dev/null || pkg-config --libs lua5.3 2>/dev/null || pkg-config --libs lua5.1 2>/dev/null || echo "-llua")

ifeq ($(UNAME_S),Darwin)
    SHLIB_FLAGS = -bundle -undefined dynamic_lookup
else
    SHLIB_FLAGS = -shared -fPIC
endif

CMARK_DIR  = vendor/cmark
CMARK_WRAP = $(CMARK_DIR)/cmark_wrap.c
CMARK_CSRC = $(wildcard $(CMARK_DIR)/ext/*.c)
CMARK_HDRS = $(wildcard $(CMARK_DIR)/ext/*.h $(CMARK_DIR)/ext/*.inc)

# tm is pure Lua; there is nothing to build. build/cmark.so (below) is a
# prerequisite of `test` only, never of `all` or `install`.
all:
	@echo "Nothing to build: tm is pure Lua. Run 'make test' or 'make install'."

build/cmark.so: $(CMARK_WRAP) $(CMARK_CSRC) $(CMARK_HDRS)
	@mkdir -p build
	$(CC) $(SHLIB_FLAGS) $(CFLAGS) $(LUA_CFLAGS) -I$(CMARK_DIR) -I$(CMARK_DIR)/ext \
	    $(LDFLAGS) -o $@ $(CMARK_WRAP) $(CMARK_CSRC) $(LUA_LDLIBS)

check: test
test: build/cmark.so check-modules
	@echo "=== tm meta Test Suite ==="
	@$(LUA) $(META_TEST)
	@echo "=== tm scan Test Suite ==="
	@$(LUA) $(SCAN_TEST)
	@echo "=== tm validate Test Suite ==="
	@$(LUA) $(TEST_RUNNER) $(TMVAL) $(FIXTURES)
	@echo "=== tm sweep Test Suite ==="
	@$(LUA) $(SWEEP_TEST)
	@echo "=== tm init Test Suite ==="
	@$(LUA) $(INIT_TEST)
	@echo "=== tm config Test Suite ==="
	@$(LUA) $(CONFIG_TEST)
	@echo "=== tm filter Test Suite ==="
	@$(LUA) $(FILTER_TEST)
	@echo "=== tm io Test Suite ==="
	@$(LUA) $(IO_TEST)
	@echo "=== tm mutate Test Suite ==="
	@$(LUA) $(MUTATE_TEST)
	@echo "=== CommonMark Conformance Oracle ==="
	@$(LUA) $(COMMONMARK_TEST)
	@echo "=== Man pages match their scdoc sources ==="
	@$(MAKE) -s man-check

# Print the current semantic version.
version:
	@cat $(VERSION_FILE)

# Build the roff man page from its scdoc source.
check-scdoc-man:
	@if ! command -v $(SCDOC) > /dev/null 2>&1; then \
		echo "ERROR: $(SCDOC) is required to build man pages." >&2; exit 1; \
	fi; \
	scdoc_ver=$$($(SCDOC) -v 2>/dev/null | awk '{print $$2}'); \
	if [ -z "$$scdoc_ver" ] || ! $(LUA) -e 'local function p(s) local a,b,c=s:match("(%d+)%.(%d+)%.?(%d*)"); return {tonumber(a) or 0,tonumber(b) or 0,tonumber(c) or 0} end; local function ge(x,y) for i=1,3 do if x[i]>y[i] then return 0 elseif x[i]<y[i] then return 1 end end return 0 end; os.exit(ge(p("'$$scdoc_ver'"), p("$(MIN_SCDOC_VERSION)")))' 2>/dev/null; then \
		echo "ERROR: $(SCDOC) >= $(MIN_SCDOC_VERSION) is required to build man pages (found $${scdoc_ver:-unknown})." >&2; \
		exit 1; \
	fi

define scdoc-render
	epoch=$$(git log -1 --format=%ct -- $(1) 2>/dev/null); \
	epoch=$${epoch:-$$SOURCE_DATE_EPOCH}; \
	SOURCE_DATE_EPOCH=$${epoch:-$$(date +%s)} $(SCDOC) < $(1)
endef

man: check-scdoc-man
	@$(call scdoc-render,$(MAN_SRC)) > $(MAN).tmp && mv $(MAN).tmp $(MAN) && echo "Generated $(MAN)"

$(MAN): $(MAN_SRC) | check-scdoc-man
	@$(call scdoc-render,$<) > $@.tmp && mv $@.tmp $@ && echo "Generated $@"

# Fails if a committed man page is stale. The scdoc version comment and the
# page date are ignored, so only real content or version drift counts.
# Skipped if scdoc is not installed or older than $(MIN_SCDOC_VERSION).
MAN_NORMALIZE    = -e '/^\.\\"/d' -e 's/^\(\.TH "[^"]*" "[^"]*"\) "[^"]*"/\1 ""/'
man-check:
	@if ! command -v $(SCDOC) > /dev/null 2>&1; then \
		echo "  SKIP: $(SCDOC) not installed"; exit 0; \
	fi; \
	scdoc_ver=$$($(SCDOC) -v 2>/dev/null | awk '{print $$2}'); \
	if [ -z "$$scdoc_ver" ] || ! $(LUA) -e 'local function p(s) local a,b,c=s:match("(%d+)%.(%d+)%.?(%d*)"); return {tonumber(a) or 0,tonumber(b) or 0,tonumber(c) or 0} end; local function ge(x,y) for i=1,3 do if x[i]>y[i] then return 0 elseif x[i]<y[i] then return 1 end end return 0 end; os.exit(ge(p("'$$scdoc_ver'"), p("$(MIN_SCDOC_VERSION)")))' 2>/dev/null; then \
		echo "  SKIP: $(SCDOC) >= $(MIN_SCDOC_VERSION) required (found $${scdoc_ver:-unknown}); skipping man page check"; exit 0; \
	fi; \
	dir=build/man-check; mkdir -p $$dir; status=0; \
	for page in $(MAN); do \
		$(call scdoc-render,$${page}.scd) > $$dir/fresh || exit 1; \
		sed $(MAN_NORMALIZE) $$page > $$dir/committed.norm; \
		sed $(MAN_NORMALIZE) $$dir/fresh > $$dir/fresh.norm; \
		if cmp -s $$dir/committed.norm $$dir/fresh.norm; then \
			echo "  PASS: $$page"; \
		else \
			echo "  FAIL: $$page is out of date; run 'make man' and commit the result"; status=1; \
		fi; \
	done; \
	$(RM) -r $$dir; exit $$status

clean:
	$(RM) -r build

dist:
	@test -n "$(GIT_COMMIT)" || { echo "make dist must run in a git checkout" >&2; exit 1; }
	@git diff --quiet HEAD -- || echo "note: uncommitted changes are not included; dist is built from HEAD ($(GIT_COMMIT))"
	mkdir -p $(DIST_DIR)
	$(RM) -r $(DIST_STAGE)
	mkdir -p $(DIST_STAGE)/$(DIST_NAME)
	git archive --format=tar HEAD | (cd $(DIST_STAGE)/$(DIST_NAME) && $(TAR) --no-same-owner -xf -)
	cd $(DIST_STAGE) && $(REPRO_TAR) -cf $(CURDIR)/$(DIST_DIR)/$(DIST_NAME).tar $(DIST_NAME)
	$(RM) -r $(DIST_STAGE)
	$(RM) $(DIST_DIR)/$(DIST_NAME).tar.xz
	$(XZ) -9 -T1 $(DIST_DIR)/$(DIST_NAME).tar
	cd $(DIST_DIR) && $(SHA256SUM) *.tar.xz > SHA256SUMS
	@echo "Source tarball for $(DIST_NAME) (commit $(GIT_COMMIT)) in $(DIST_DIR)/:"
	@cat $(DIST_DIR)/SHA256SUMS

dist-bin:
	@test -n "$(GIT_COMMIT)" || { echo "make dist-bin must run in a git checkout" >&2; exit 1; }
	@git diff --quiet HEAD -- || echo "note: uncommitted changes are not included; dist-bin is built from HEAD ($(GIT_COMMIT))"
	mkdir -p $(DIST_DIR)
	$(RM) -r $(DIST_STAGE)
	mkdir -p $(DIST_STAGE)/src $(DIST_STAGE)/install-root
	git archive --format=tar HEAD | (cd $(DIST_STAGE)/src && $(TAR) --no-same-owner -xf -)
	$(MAKE) -s -C $(DIST_STAGE)/src install DESTDIR=$(CURDIR)/$(DIST_STAGE)/install-root PREFIX=$(PREFIX) TM_VERSION_FULL="$(TM_VERSION_FULL)" > /dev/null
	cd $(DIST_STAGE)/install-root && $(REPRO_TAR) -cf $(CURDIR)/$(DIST_DIR)/$(DIST_BIN_NAME).tar .
	$(RM) -r $(DIST_STAGE)
	$(RM) $(DIST_DIR)/$(DIST_BIN_NAME).tar.xz
	$(XZ) -9 -T1 $(DIST_DIR)/$(DIST_BIN_NAME).tar
	cd $(DIST_DIR) && $(SHA256SUM) *.tar.xz > SHA256SUMS
	@echo "Installed binary tarball for $(DIST_BIN_NAME) (commit $(GIT_COMMIT)) in $(DIST_DIR)/:"
	@cat $(DIST_DIR)/SHA256SUMS

help:
	@echo "Taskmark Makefile targets:"
	@echo "  all                 Nothing to build -- tm is pure Lua"
	@echo "  check / test        Run full test suite (needs C compiler for oracle)"
	@echo "  dist                Build reproducible source tarball in $(DIST_DIR)/"
	@echo "  dist-bin            Build reproducible installed contents tarball in $(DIST_DIR)/"
	@echo "  install             Install tm to $(BINDIR) (PREFIX=$(PREFIX))"
	@echo "  man                 Regenerate tm(1) man page (needs scdoc >= $(MIN_SCDOC_VERSION))"
	@echo "  install-bin         Install only binaries and Lua modules"
	@echo "  install-man         Install only manual page ($(MANDIR))"
	@echo "  install-version     Install VERSION file ($(SHAREDIR))"
	@echo "  uninstall           Uninstall all files"
	@echo "  clean               Remove build/ staging artifacts"
	@echo "  version             Print current version"
	@echo "  help                Show this help"

install: install-bin install-man install-version

install-bin:
	$(INSTALL_DIR) $(BINDIR) $(SHAREDIR) $(DOCDIR)
	$(INSTALL_PROGRAM) src/tm $(BINDIR)/tm
	$(INSTALL_DATA) $(addprefix src/,$(MODULES)) $(SHAREDIR)/
	$(INSTALL_DATA) doc/taskmark_spec.md $(DOCDIR)/taskmark_spec.md
	$(INSTALL_DATA) LICENSE $(DOCDIR)/LICENSE

install-version: $(VERSION_FILE)
	$(INSTALL_DIR) $(SHAREDIR)
	echo '$(TM_VERSION_FULL)' > $(SHAREDIR)/VERSION

install-man:
	@if [ -f $(MAN) ]; then \
		$(INSTALL_DIR) $(MANDIR); \
		$(INSTALL_DATA) $(MAN) $(MANDIR)/tm.1; \
	else \
		echo "ERROR: $(MAN) not found; run 'make man' first" >&2; exit 1; \
	fi

uninstall:
	$(RM) $(BINDIR)/tm
	$(RM) $(addprefix $(SHAREDIR)/,$(MODULES))
	$(RM) $(SHAREDIR)/VERSION
	$(RM) $(DOCDIR)/taskmark_spec.md $(DOCDIR)/LICENSE
	$(RM) $(MANDIR)/tm.1
	-$(RMDIR) $(SHAREDIR) 2>/dev/null || true
	-$(RMDIR) $(DOCDIR) 2>/dev/null || true
	-$(RMDIR) $(MANDIR) 2>/dev/null || true
