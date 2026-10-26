#!/bin/zsh
# Checks that nothing personal is about to be published: scans every tracked file, and every
# commit's author, committer and message, for the strings listed in .public-denylist (one per
# line, case-insensitive; the file is ignored by git so the list itself stays private).
# Run before every push.
set -euo pipefail
cd "$(dirname "$0")/.."
list=.public-denylist
[[ -f $list ]] || { echo "No $list: add your name, email, team ID and so on, one per line."; exit 1; }
patterns=("${(@f)$(grep -v -e '^#' -e '^[[:space:]]*$' $list)}")
found=0
for p in $patterns; do
  if git grep -I -i -F -n -e "$p" -- . >/dev/null; then
    echo "In files: '$p'"; git grep -I -i -F -n -e "$p" -- . | head -5; found=1
  fi
  if git log --all --format='%an %ae %cn %ce%n%B' | grep -i -F -e "$p" >/dev/null; then
    echo "In commit history: '$p'"; found=1
  fi
  if git log --all -p --format= | grep -i -F -e "$p" >/dev/null; then
    echo "In an earlier version of a file: '$p'"; found=1
  fi
done
if (( found )); then echo "Personal info found. Don't push."; exit 1; fi
echo "Clean: none of the ${#patterns} personal strings appear in the files or history."
