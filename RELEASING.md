# Releasing

pickpen is released as three files on a GitHub release tagged `v<x.y.z>` here: the program for
macOS on Apple silicon (`arm64`) and for Linux on `arm64` and `x86_64`, named
`pickpen-<version>-<target>`, with a `SHA256SUMS` that names the three. There is no Intel Mac
file: bateri, the terminal that shows the page, runs on Apple silicon only, and a Linux file is
for the server a pipeline runs on over ssh. It is not published on npm. Every step a machine can
check is in `tools/release.sh`, behind the `make` targets below. This file is the order of the
steps and the reasons for them.

## Versions and the changelog

pickpen follows [semantic versioning](https://semver.org/). While it is `0.x`, a minor release
may change what the previous one did.

Every change a user would notice goes under `## [Unreleased]` in `CHANGELOG.md`
([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)), in the same commit as the change. A
release only moves that section under a version and a date; it does not write it.

## What a release needs

Each of the three files is the runner of pencere's Lua runner for one target, with pickpen's
program, page and icons packed into it. So a release needs:

- the `pencere` command and the runners of the three targets, of one version: `make dist` in a
  pencere checkout makes them in its `dist/` (`pencere-<version>-<target>`). When pencere has a
  release, `pencere build --target` fetches the runner of a target itself and `make dist` stops
  asking for `RUNNERS`. The runner has to be one that reads standard input as it arrives
  (`io.read_stdin`), shows a filter's view (`serve{ filter = true }`), starts a program in a session
  of its own (`session = true`) and ends its view (`close_view`).
- `gh`, logged in, to make the GitHub release.

The files are built on the maintainer's machine and not by a workflow: an executable that a
workflow built is one that a pushed tag changes without a maintainer's decision. CI runs the gate
(`make check`) on a runner it builds from pencere; a release runs it here as well.

## A release

From a clean `main`, with `PENCERE`, `FAKE_HOST` and `PENCERE_KIT` pointing at the pencere
checkout's `pencere` command, `pencere-fake-host` and `kit/luau/prelude` if they are not where the
Makefile looks:

1. `make release-prepare VERSION=0.1.0` sets the version in `src/program/version.lua` (the program
   is one file with no manifest beside it, so it carries its version in its source), and turns
   `## [Unreleased]` into `## [0.1.0] - <today>` with a new, empty `## [Unreleased]` above it.
   Read the diff, then commit it as `Release pickpen 0.1.0`.
2. `make dist RUNNERS=<the pencere checkout's dist/>`, from that commit, on a clean tree. The file
   names carry the version, so a `dist/release` built before the version moved is refused; nothing
   can tell which source a `dist/release` of the right version was built from, so build it after
   the commit and not before.
3. `make release` runs the gate (`make check`), then the release checks, then makes the annotated
   tag `v0.1.0` with the changelog section as its message. Nothing is pushed.
4. `make publish` pushes `main` and the tag in one atomic push, then makes the GitHub release with
   the changelog section as its notes, the three files and `SHA256SUMS`.
5. Check it: `gh release view v0.1.0`.

If a check fails, nothing has left the machine: fix it, amend or add a commit, and run the step
again. A tag that was made but not pushed can be deleted with `git tag -d <tag>`. A pushed tag is
never moved; a broken release is followed by a new version. If the push went and `gh` failed, the
tag is on `origin` and the release is not: make it by hand with `gh release create v0.1.0
--verify-tag` and the files of `dist/release`.

### What the release checks refuse

- a version that is not after the last, or a `src/program/version.lua` that disagrees with the
  newest changelog section;
- an `## [Unreleased]` section that still holds changes, or an empty release section;
- a branch other than `main`, a working tree that is not clean, a `main` that has diverged from
  `origin/main`;
- a tag that already exists, here or on `origin`;
- a `dist/release` that is not exactly the three files of this version and `SHA256SUMS`, with the
  sum of each as listed.

## Who releases

`make publish` makes the release under the project's name. Only a maintainer runs it. Everything
before it (prepare, commit, dist, tag) can be undone locally.
