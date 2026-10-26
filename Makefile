# pickpen is one native file: a Rust program with its view (src/view/, a page of pencere's kit, and
# src/assets/) carried in it. The gate and the steps of a release are here; RELEASING.md says in what
# order and why.
.PHONY: check fmt lint build test test-program test-page test-binary test-tools dist sums release-prepare rehearse demo

# The view's tests run in pencere's Lua runner, the `pencere` command: a release of it, which
# pencere's installer puts in ~/.local/bin (curl -fsSL https://raw.githubusercontent.com/bateri/pencere/main/cli/install.sh | sh;
# PENCERE_VERSION=<it> for the version in tools/pencere-version), or one built in a pencere checkout
# (cargo build --release -p pencere-cli). They run the view against the kit's own page API, the
# prelude of a pencere checkout (PRELUDE). The stand-in terminal the end-to-end tests play pickpen in
# has no release: it is built in a pencere checkout (cargo build -p pencere-fake-host). Where they
# are not where the Makefile looks, say so:
#
#   make check PENCERE=../pencere/target/release/pencere \
#              PRELUDE=../pencere/kit/luau/prelude \
#              FAKE_HOST=../pencere/target/debug/pencere-fake-host
PENCERE ?= $(shell command -v pencere 2>/dev/null || echo ../pencere/target/release/pencere)
PRELUDE ?= ../pencere/kit/luau/prelude
FAKE_HOST ?= ../pencere/target/debug/pencere-fake-host
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

# build makes dist/pickpen, the program for this machine.
build:
	cargo build --locked --release
	mkdir -p dist
	cp target/release/pickpen dist/pickpen

# test-program runs the program's own tests: the query, the input's shapes, the output, the
# arguments, what the view is told.
test-program:
	cargo test --locked

# test-page runs the view against the kit's page API, with a stand-in for its program, in pencere's
# Lua runner: what it asks, what it shows of what it is told, what its keys and clicks do.
test-page:
	@test -x "$(PENCERE)" || { echo "test-page: the pencere command is not at $(PENCERE): see PENCERE at the top of the Makefile"; exit 1; }
	PENCERE="$(PENCERE)" PENCERE_PRELUDE="$(PRELUDE)" node --test test/lua.test.mjs

# test-binary runs the built program: with nobody to ask (`--where`), and in a pane under the
# stand-in terminal, with the view's calls. Nothing in it is skipped; a stand-in that is not there
# stops the run.
test-binary:
	@test -x "$(FAKE_HOST)" || { echo "test-binary: pencere-fake-host is not at $(FAKE_HOST): build it in a pencere checkout (cargo build -p pencere-fake-host), then make check FAKE_HOST=<it>"; exit 1; }
	PENCERE_FAKE_HOST="$(FAKE_HOST)" PICKPEN_BIN=dist/pickpen node --test test/program.test.mjs

# test-tools runs the tests of the installer (install.sh) against a stand-in for GitHub.
test-tools:
	node --test test/install.test.mjs

test: test-program test-page test-binary test-tools

# check is the gate: formatting and clippy, the program built, its tests, the built program held to
# what the view expects of it, and the installer.
check: lint build test

# dist makes the program for one target (TARGET, a Rust target triple) into dist/release, as
# pickpen-<version>-<target>. The release workflow runs it on a machine of each of the three
# targets pickpen ships (Apple silicon Macs and both Linux architectures, the Linux ones linked
# statically with musl; bateri, the terminal that shows the view, runs on Apple silicon only), then
# `make sums` where the three files are together.
TARGETS = aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl
PACKAGE_VERSION = $(shell node tools/release.mjs version)

dist:
	@test -n "$(TARGET)" || { echo "usage: make dist TARGET=<one of: $(TARGETS)>"; exit 2; }
	cargo build --locked --release --target $(TARGET)
	mkdir -p dist/release
	cp target/$(TARGET)/release/pickpen dist/release/pickpen-$(PACKAGE_VERSION)-$(TARGET)

# sums writes the SHA256SUMS of the three files of dist/release, and checks them.
sums:
	cd dist/release && { sha256sum pickpen-* 2>/dev/null || shasum -a 256 pickpen-*; } > SHA256SUMS
	@cat dist/release/SHA256SUMS
	node tools/release.mjs dist dist/release

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	node tools/release.mjs prepare $(VERSION)

# rehearse runs the checks of a release of the prepared version, on any branch. It changes nothing:
# a release is the commit of release-prepare pushed to main, which the release workflow tags,
# builds and drafts once the gate is green, and publishes when a maintainer approves (RELEASING.md).
rehearse:
	node tools/release.mjs rehearse

# demo writes the inputs of demo/ again, the same every time.
demo:
	node tools/demo.mjs
