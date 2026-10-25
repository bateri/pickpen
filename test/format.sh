#!/bin/sh
# The format of the sources, as far as it can be checked without a formatter for Luau: Lua
# indented with tabs, no trailing spaces anywhere, a line of at most 100 columns in Lua, and a
# final newline.
status=0
for file in $(git ls-files -co --exclude-standard '*.lua' '*.md' '*.yml' '*.sh' Makefile); do
	if grep -nE ' +$' "$file" >/dev/null 2>&1; then
		echo "format: $file has trailing spaces: $(grep -nE ' +$' "$file" | head -1)"; status=1
	fi
	if [ -s "$file" ] && [ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]; then
		echo "format: $file has no final newline"; status=1
	fi
	case "$file" in
	*.lua)
		# Text in a long string ([[ ... ]]) is the string's, whatever its indent.
		spaces=$(awk '/\[\[$/ { inside = 1; next } /^\]\]/ { inside = 0; next } !inside && /^ +[^ ]/ { print NR; exit }' "$file")
		if [ -n "$spaces" ]; then
			echo "format: $file is indented with spaces at line $spaces"; status=1
		fi
		if awk '{ gsub(/\t/, "    "); if (length($0) > 100) { print FILENAME ":" NR ": " length($0) " columns"; bad = 1 } } END { exit bad }' "$file" >/dev/null; then :; else
			echo "format: $file has a line over 100 columns: $(awk '{ gsub(/\t/, "    "); if (length($0) > 100) { print NR; exit } }' "$file")"; status=1
		fi
		;;
	esac
done
exit $status
