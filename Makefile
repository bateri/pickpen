# pickpen is one native file: pencere's Lua runner with the program (src/program/, Lua), the page
# (src/view/, Lua) and the icons (src/assets/) packed into it. The gate and the steps of a release
# are here; RELEASING.md says in what order and why.
.PHONY: check fmt-check test-lua build test-binary dist release-prepare release publish

# `pencere` is the command of a pencere checkout, built there (cargo build --release -p
# pencere-cli); the stand-in terminal the end-to-end tests play pickpen in is built there too
# (cargo build -p pencere-fake-host). The runner has to be one that reads standard input as it
# arrives (`io.read_stdin`) and shows a filter's view (`serve{ filter = true }`).
PENCERE ?= ../pencere/target/release/pencere
FAKE_HOST ?= ../pencere/target/debug/pencere-fake-host
# The page API a terminal gives a page is Lua (the kit's prelude); the page's tests run the page on
# the kit's own files.
PENCERE_KIT ?= ../pencere/kit/luau/prelude

# check is the gate: the sources are formatted, the program's modules pass their tests, the
# program is built, and the built file passes the end-to-end tests under the stand-in terminal.
check: fmt-check test-lua build test-binary

# fmt-check is the format of the Lua: tabs, no trailing spaces, a line of 100 columns at most,
# a final newline. (There is no formatter for Luau to run, so this is what is checked.)
fmt-check:
	@sh test/format.sh

# test-lua runs the tests of the modules and of the page, `test/lua/cases/*.lua`, in a test app made
# of the program's modules (without its app.lua), the page and the tests. CASES names the files to
# pack, ONLY a piece of the name of the tests to run, TESTDIR where the test app is made.
TESTDIR ?= dist/test
CASES ?= $(patsubst test/lua/cases/%.lua,%,$(wildcard test/lua/cases/*.lua))
ONLY ?=
test-lua:
	@test -x "$(PENCERE)" || { echo "test-lua: the pencere command is not at $(PENCERE): build it in a pencere checkout (cargo build --release -p pencere-cli), then make test-lua PENCERE=<it>"; exit 1; }
	rm -rf $(TESTDIR)-app && mkdir -p $(TESTDIR)-app/cases
	cp -R src/program/. $(TESTDIR)-app/
	rm -f $(TESTDIR)-app/app.lua
	cp test/lua/*.lua $(TESTDIR)-app/
	mkdir -p $(TESTDIR)-app/view && cp src/view/*.lua $(TESTDIR)-app/view/
	for c in $(CASES); do cp test/lua/cases/$$c.lua $(TESTDIR)-app/cases/ || exit 1; done
	"$(PENCERE)" build $(TESTDIR)-app --name test -o $(TESTDIR)-run
	PENCERE_KIT="$(PENCERE_KIT)" ./$(TESTDIR)-run cases $(ONLY)

# build makes dist/pickpen, the program for this machine, as one file: src/program/, src/view/
# and src/assets/ packed into the runner.
build:
	@test -x "$(PENCERE)" || { echo "build: the pencere command is not at $(PENCERE): build it in a pencere checkout (cargo build --release -p pencere-cli), then make build PENCERE=<it>"; exit 1; }
	"$(PENCERE)" build --name pickpen -o dist/pickpen

# test-binary runs the program, dist/pickpen, in a pipeline in a pane under the stand-in terminal,
# and as cron would run it: the choices made through the page's calls, and the bytes that come
# out. Nothing in it is skipped; a program or a stand-in that is not there stops the run.
test-binary:
	@test -x "$(FAKE_HOST)" || { echo "test-binary: pencere-fake-host is not at $(FAKE_HOST): build it in a pencere checkout (cargo build -p pencere-fake-host), then make check FAKE_HOST=<it>"; exit 1; }
	@test -x dist/pickpen || { echo "test-binary: dist/pickpen is not built: make build"; exit 1; }
	rm -rf dist/binary-app && mkdir -p dist/binary-app/binary
	cp -R src/program/. dist/binary-app/
	rm -f dist/binary-app/app.lua
	cp test/lua/app.lua test/lua/t.lua dist/binary-app/
	cp test/lua/binary/*.lua dist/binary-app/binary/
	"$(PENCERE)" build dist/binary-app --name test -o dist/binary-run
	PICKPEN_BIN="$(CURDIR)/dist/pickpen" PENCERE_FAKE_HOST="$(FAKE_HOST)" PICKPEN_DEMO="$(CURDIR)/demo" ./dist/binary-run binary

# dist makes the program for the three targets pickpen ships (Apple silicon Macs and both Linux
# architectures: it runs on the machine the pipeline is on, and over ssh that is a server) into
# dist/release, with the SHA256SUMS that names them. The runners come from a pencere checkout's
# `make dist` (RUNNERS=<its dist/>), one for each target, of the version of the `pencere` command.
# When pencere has a release, `pencere build --target T` fetches them itself and --runner goes away.
TARGETS = aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl
RUNNERS ?= ../pencere/dist
PACKAGE_VERSION = $(shell sed -n 's/^return "\(.*\)"$$/\1/p' src/program/version.lua)
RUNNER_VERSION = $(shell "$(PENCERE)" --version | sed 's/^pencere //')

dist:
	@test -x "$(PENCERE)" || { echo "dist: the pencere command is not at $(PENCERE): see PENCERE at the top of the Makefile"; exit 1; }
	rm -rf dist/release
	mkdir -p dist/release
	@for target in $(TARGETS); do \
		runner="$(RUNNERS)/pencere-$(RUNNER_VERSION)-$$target"; \
		test -f "$$runner" || { echo "dist: no runner for $$target at $$runner: make dist in a pencere checkout, then make dist RUNNERS=<its dist/>"; exit 1; }; \
		"$(PENCERE)" build --name pickpen --target $$target --runner "$$runner" -o dist/release/pickpen-$(PACKAGE_VERSION)-$$target || exit 1; \
	done
	cd dist/release && shasum -a 256 pickpen-* > SHA256SUMS
	@cat dist/release/SHA256SUMS

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	sh tools/release.sh prepare $(VERSION)

# release runs the gate and the release checks (dist/release holds the three files of this
# version, made after the release commit), then tags. Nothing is pushed.
release: check
	sh tools/release.sh tag

# publish pushes main and the tag, then makes the GitHub release with the three files and
# SHA256SUMS. Publishing: run on the maintainer's word.
publish:
	sh tools/release.sh publish
