# pickpen is one native file: a Rust program with its view (src/view/, a page of pencere's kit, and
# src/assets/) carried in it. The gate and the steps of a release are here; RELEASING.md says in what
# order and why.
.PHONY: check fmt lint pencere-src pencere fake-host pencere-ref build dev test test-program test-page test-binary test-tools dist sums release-prepare release publish demo

# pencere is what pickpen is built with, and tested with: the `pencere` crate the program is built
# on, and from the same pencere, its `pencere` command (the Lua runner the view's tests run in, and
# `pencere dev`, and `pencere dist`, which signs a release), its stand-in terminal the end-to-end
# tests play pickpen in (pencere-fake-host) and the prelude of its kit, the page API the view's tests
# hold the view to. Cargo.lock is the one place it is pinned: a commit of pencere while pickpen needs
# what no release of it has, a release on crates.io once one does (`make pencere-ref` says which, as
# a git ref).
#
# The command, the stand-in and the prelude come from one checkout of pencere, PENCERE_SRC, built
# there by `make pencere`, which the steps that need them run first. By default it is pencere at
# that ref, fetched into .cache/pencere, so the gate holds pickpen to the pencere it is built with
# and to nothing else, on any machine. To work against another checkout, a pencere you are
# changing, say so; one that is not at Cargo.lock's ref is said to be so:
#
#   make dev PENCERE_SRC=../pencere
# The ref is the commit Cargo.lock takes it at, or the tag of the crates' release it takes.
PENCERE_REF = $(shell awk '/^name = "pencere"$$/ { getline v; getline s; gsub(/version = |"/, "", v); if (s ~ /^source = "registry/) print "crates-v" v; else { sub(/.*\#/, "", s); sub(/"$$/, "", s); print s } exit }' Cargo.lock)
PENCERE_CACHE = .cache/pencere
PENCERE_SRC ?= $(PENCERE_CACHE)
PENCERE ?= $(PENCERE_SRC)/target/release/pencere
FAKE_HOST ?= $(PENCERE_SRC)/target/debug/pencere-fake-host
PRELUDE ?= $(PENCERE_SRC)/kit/luau/prelude
PENCERE_GIT = https://github.com/bateri/pencere

# The Lua files are formatted with StyLua (cargo install stylua --locked --features luau).
STYLUA ?= stylua

# fmt formats the Rust and the Lua.
fmt:
	cargo fmt
	$(STYLUA) src/view test/lua

# lint is the formatting, checked, and clippy.
lint:
	cargo fmt --check
	@command -v "$(STYLUA)" >/dev/null || { echo "lint: StyLua is not installed: cargo install stylua --locked --features luau"; exit 1; }
	$(STYLUA) --check src/view test/lua
	cargo clippy --locked --all-targets -- -D warnings

# pencere-src makes PENCERE_SRC ready: fetched at Cargo.lock's ref when it is the cache, so that the
# command and the stand-in terminal built there are the pencere its prelude is. The cache is one
# checkout, moved to another ref when Cargo.lock moves, so that cargo builds again only what changed.
pencere-src:
	@command -v cargo >/dev/null || { echo "pencere: cargo is not installed: pencere is built from its source (https://rustup.rs)"; exit 1; }
	@ref="$(PENCERE_REF)"; test -n "$$ref" || { echo "pencere: Cargo.lock takes no pencere"; exit 1; }; \
	if [ "$(PENCERE_SRC)" = "$(PENCERE_CACHE)" ]; then \
		if [ "$$(cat $(PENCERE_CACHE).ref 2>/dev/null)" != "$$ref" ]; then \
			echo "pencere: fetching $(PENCERE_GIT) at $$ref into $(PENCERE_CACHE)"; \
			{ test -d "$(PENCERE_CACHE)/.git" || git init -q "$(PENCERE_CACHE)"; } && \
			git -C "$(PENCERE_CACHE)" fetch -q --depth 1 "$(PENCERE_GIT)" "$$ref" && \
			git -C "$(PENCERE_CACHE)" checkout -q --detach --force FETCH_HEAD && \
			echo "$$ref" > "$(PENCERE_CACHE).ref" || exit 1; \
		fi; \
	else \
		head=$$(git -C "$(PENCERE_SRC)" rev-parse HEAD 2>/dev/null); \
		want=$$(git -C "$(PENCERE_SRC)" rev-parse -q --verify "$$ref^{commit}" 2>/dev/null); \
		[ -n "$$head" ] && [ "$$head" = "$$want" ] || \
			echo "pencere: $(PENCERE_SRC) is at $${head:-no commit}, not at $$ref (Cargo.lock) that pickpen is built with"; \
	fi

# pencere builds the `pencere` command in PENCERE_SRC.
pencere: pencere-src
	cd "$(PENCERE_SRC)" && cargo build --release -p pencere-cli

# fake-host builds the stand-in terminal in PENCERE_SRC.
fake-host: pencere-src
	cd "$(PENCERE_SRC)" && cargo build -p pencere-fake-host

# pencere-ref says which pencere Cargo.lock takes.
pencere-ref:
	@echo "$(PENCERE_REF)"

# build makes dist/pickpen, the program for this machine.
build:
	cargo build --locked --release
	mkdir -p dist
	cp target/release/pickpen dist/pickpen

# dev runs pickpen from its files in this pane, and again when one of them changes (the program
# built by Cargo, the view shown again without ending it): in a pane of a terminal that hosts
# pencere (bateri).
dev: pencere
	"$(PENCERE)" dev

# test-program runs the program's own tests: the query, the input's shapes, the output, the
# arguments, what the view is told.
test-program:
	cargo test --locked

# test-page runs the view against the kit's page API, with a stand-in for its program, in pencere's
# Lua runner: what it asks, what it shows of what it is told, what its keys and clicks do.
test-page: pencere
	PENCERE="$(PENCERE)" PENCERE_PRELUDE="$(PRELUDE)" node --test test/lua.test.mjs

# test-binary runs the built program: with nobody to ask (`--where`), and in a pane under the
# stand-in terminal, with the view's calls. Nothing in it is skipped; a stand-in that is not there
# stops the run.
test-binary: fake-host
	PENCERE_FAKE_HOST="$(FAKE_HOST)" PICKPEN_BIN=dist/pickpen node --test test/program.test.mjs

# test-tools runs the tests of the installer (install.sh) against a stand-in for GitHub, and those of
# the release checks (tools/release-files.mjs), against a directory of their own.
test-tools:
	node --test test/install.test.mjs test/release.test.mjs

test: test-program test-page test-binary test-tools

# check is the gate: formatting and clippy, the program built, its tests, the built program held to
# what the view expects of it, and the installer.
check: lint build test

# dist makes the program for one target (TARGET, a Rust target triple) into dist/release, as
# pickpen-<version>-<target>: Apple silicon Macs and both Linux architectures, the Linux ones linked
# statically with musl (bateri, the terminal that shows the view, runs on Apple silicon only). Each
# is built on a machine of its own target, with that target added to the toolchain; `make sums` then
# names the three where they are together, and signs the app.json that says what they are.
TARGETS = aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl
PACKAGE_VERSION = $(shell sed -n 's/^version = "\(.*\)"$$/\1/p' Cargo.toml | head -n 1)

dist:
	@test -n "$(TARGET)" || { echo "usage: make dist TARGET=<one of: $(TARGETS)>"; exit 2; }
	cargo build --locked --release --target $(TARGET)
	mkdir -p dist/release
	cp target/$(TARGET)/release/pickpen dist/release/pickpen-$(PACKAGE_VERSION)-$(TARGET)

# sums writes the SHA256SUMS of the three files of dist/release, then the app.json that names them
# and its signature (`pencere dist`, which signs with the key `pencere key` made: ~/.config/pencere/
# signing.key, or the one PENCERE_SIGNING_KEY names). A terminal that follows pickpen reads those
# two. What the program needs of its terminal in app.json comes from the program itself, the file
# of this machine's target, started once: pickpen needs rows to start, and with nobody typing it has
# none, so it is started as `pickpen --reload true` (--describe-args), rows from a command that
# prints none. DIST_FLAGS goes to `pencere dist`: --base, --previous.
#
# On release day PENCERE must be a pencere that has `dist` and is the one Cargo.lock takes
# (PENCERE_REF): `make pencere` builds it. A release made with another one has an app.json that
# the pencere pickpen is built with did not write.
DIST_FLAGS ?=
sums:
	cd dist/release && { sha256sum pickpen-* 2>/dev/null || shasum -a 256 pickpen-*; } > SHA256SUMS
	@cat dist/release/SHA256SUMS
	@test -x "$(PENCERE)" || { echo "sums: no pencere at $(PENCERE): make pencere, or PENCERE=<a pencere command that has dist>"; exit 1; }
	"$(PENCERE)" dist --files dist/release --describe-args "--reload true" $(DIST_FLAGS) $(PACKAGE_VERSION)

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	node tools/release.mjs prepare $(VERSION)

# release runs the gate and the release checks (dist/release holds the three files of this
# version and their SHA256SUMS, made after the release commit), then tags. Nothing is pushed.
release: check
	node tools/release.mjs tag

# publish pushes main and the tag, then makes the GitHub release with the three files and
# SHA256SUMS. Publishing: run on the maintainer's word.
publish:
	node tools/release.mjs publish

# demo writes the inputs of demo/ again, the same every time.
demo:
	node tools/demo.mjs
