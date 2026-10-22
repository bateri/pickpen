# The gate and the steps of a release; RELEASING.md says in what order and why.
.PHONY: setup check demo harness release-prepare release publish publish-local approve

setup:
	npm ci

# check is the gate: types, formatting, the build, and the tests against what it built: the
# input's shapes, the query, the output, the view's server, the program with nobody to ask, and
# pickpen in a pipeline in a pane under pencere-fake-host when a pencere checkout beside this one
# has built it (otherwise those tests say they were skipped).
check:
	npm run typecheck
	npx prettier --check .
	npm test

# demo writes the inputs of demo/ again, the same every time.
demo:
	node tools/demo.mjs

# harness serves the view in a browser on :5199, with pickpen's server behind it.
harness:
	npm run harness

# release-prepare sets the version and dates the changelog's Unreleased section.
release-prepare:
	@test -n "$(VERSION)" || { echo "usage: make release-prepare VERSION=<x.y.z>"; exit 2; }
	node tools/release.mjs prepare $(VERSION)

# release runs the gate and the release checks, then tags. Nothing is pushed.
release: check
	node tools/release.mjs tag

# publish pushes main and the tag; the release workflow stages the package and a
# maintainer approves it on npm with 2FA. Publishing: run on the maintainer's word.
publish:
	node tools/release.mjs push

# publish-local publishes from this machine, then pushes: the first release, before the
# registry knows the package and its trusted publisher.
publish-local:
	node tools/release.mjs local

# approve makes public the version the release workflow staged on npm, with 2FA.
# Publishing: run on the maintainer's word.
approve:
	node tools/release.mjs approve
