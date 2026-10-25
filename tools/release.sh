#!/bin/sh
# The steps of a release that a machine can check (RELEASING.md says in what order and why):
#
#   release.sh prepare VERSION   the version, and the changelog's Unreleased section dated
#   release.sh tag               the checks, then the annotated tag; nothing is pushed
#   release.sh publish           pushes main and the tag, then makes the GitHub release
#
# It changes nothing but what it says, and it refuses before it changes anything.

set -eu

cd "$(dirname "$0")/.."

CHANGELOG=CHANGELOG.md
VERSION_FILE=src/program/version.lua
TARGETS="aarch64-apple-darwin aarch64-unknown-linux-musl x86_64-unknown-linux-musl"

die() {
	echo "release: $*" >&2
	exit 1
}

# The version the program carries.
program_version() {
	sed -n 's/^return "\(.*\)"$/\1/p' "$VERSION_FILE"
}

# The newest version the changelog has a section for ("" when it has none).
changelog_version() {
	sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$CHANGELOG" | head -n 1
}

# The lines of the section `$1` ("Unreleased" or a version), without its heading.
section() {
	awk -v want="$1" '
		/^## \[/ { inside = ($0 ~ "^## \\[" want "\\]"); next }
		inside { print }
	' "$CHANGELOG"
}

# Whether version `$1` is after version `$2` (both x.y.z).
is_after() {
	[ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}

valid_version() {
	printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

prepare() {
	version=${1:-}
	valid_version "$version" || die "usage: release.sh prepare <x.y.z>"
	last=$(changelog_version)
	if [ -n "$last" ] && ! is_after "$version" "$last"; then
		die "$version is not after the last release, $last"
	fi
	[ -n "$(section Unreleased | tr -d ' \n')" ] || die "the changelog's Unreleased section is empty: there is nothing to release"
	today=$(date +%Y-%m-%d)
	awk -v version="$version" -v today="$today" '
		/^## \[Unreleased\]/ && !done { print; print ""; print "## [" version "] - " today; done = 1; next }
		{ print }
	' "$CHANGELOG" > "$CHANGELOG.new"
	mv "$CHANGELOG.new" "$CHANGELOG"
	printf -- '-- pickpen'"'"'s version. A built program is one file with no manifest beside it, so it carries its\n-- version in its source; `make release-prepare` changes it, and nothing else does.\nreturn "%s"\n' "$version" > "$VERSION_FILE"
	echo "release: $version prepared; read the diff, then commit it as: Release pickpen $version"
}

# What a release refuses, before it tags.
check() {
	version=$(program_version)
	valid_version "$version" || die "$VERSION_FILE has no version"
	[ "$(changelog_version)" = "$version" ] || die "the newest changelog section is $(changelog_version), the program says $version"
	[ -z "$(section Unreleased | tr -d ' \n')" ] || die "the changelog's Unreleased section still holds changes: they belong to a release"
	[ -n "$(section "$version" | tr -d ' \n')" ] || die "the changelog's section for $version is empty"
	[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || die "a release is made from main"
	[ -z "$(git status --porcelain)" ] || die "the working tree is not clean"
	if git remote get-url origin > /dev/null 2>&1; then
		git fetch --quiet origin main || die "origin cannot be reached"
		git merge-base --is-ancestor origin/main HEAD || die "main has diverged from origin/main"
		! git ls-remote --exit-code --tags origin "refs/tags/v$version" > /dev/null 2>&1 || die "v$version is already on origin"
	fi
	! git rev-parse -q --verify "refs/tags/v$version" > /dev/null || die "v$version already exists here"
	files=$(ls dist/release 2> /dev/null | grep -v '^SHA256SUMS$' | sort | tr '\n' ' ')
	wanted=$(for target in $TARGETS; do printf 'pickpen-%s-%s ' "$version" "$target"; done | tr ' ' '\n' | sort | tr '\n' ' ')
	[ "$files" = "$wanted" ] || die "dist/release holds [$files], a release of $version holds [$wanted] (make dist, after the release commit)"
	(cd dist/release && shasum -a 256 -c SHA256SUMS > /dev/null) || die "dist/release does not match its SHA256SUMS"
	for target in $TARGETS; do
		grep -q "pickpen-$version-$target\$" dist/release/SHA256SUMS || die "SHA256SUMS does not name the file for $target"
	done
	echo "release: the checks hold for $version"
}

tag() {
	check
	version=$(program_version)
	notes=$(mktemp)
	{
		echo "pickpen $version"
		echo
		section "$version"
	} > "$notes"
	git tag -a "v$version" -F "$notes"
	rm -f "$notes"
	echo "release: tagged v$version; nothing is pushed (make publish does that)"
}

publish() {
	version=$(program_version)
	git rev-parse -q --verify "refs/tags/v$version" > /dev/null || die "v$version is not tagged here: make release first"
	command -v gh > /dev/null || die "gh is needed to make the GitHub release"
	git push --atomic origin main "v$version"
	notes=$(mktemp)
	section "$version" > "$notes"
	gh release create "v$version" --verify-tag --title "pickpen $version" --notes-file "$notes" dist/release/*
	rm -f "$notes"
}

case "${1:-}" in
prepare) shift; prepare "$@" ;;
check) check ;;
tag) tag ;;
publish) publish ;;
*) die "usage: release.sh prepare <x.y.z> | check | tag | publish" ;;
esac
