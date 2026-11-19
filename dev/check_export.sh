#!/usr/bin/env bash
# Check that the files shipped to the consumers of the action (git archive, which applies the
# export-ignore rules of .gitattributes) are exactly the files the action needs at runtime.
# `uses: ./` runs the whole checkout, so a file marked export-ignore by mistake would pass the
# tests and break the release. When the action starts using a new file, add it to EXPECTED here
# and un-ignore it in .gitattributes.
set -euo pipefail

EXPECTED="LICENSE
action.yaml"

actual=$(git archive --worktree-attributes HEAD | tar t | LC_ALL=C sort)
expected=$(printf '%s\n' "$EXPECTED" | LC_ALL=C sort)

if [ "$actual" != "$expected" ]; then
	echo "::error::The exported files differ from the files the action needs (see dev/check_export.sh)"
	diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") || true
	exit 1
fi
echo "✅ The exported files are the expected ones:"
printf '%s\n' "$actual"
