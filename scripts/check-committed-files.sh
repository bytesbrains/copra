#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# Copra Protocol - Committed-files check
# Refuses files that should never reach the repo's history: local tool state, files .gitignore
# excludes, unexpected binaries and very large files. It checks every commit in the range, not just
# the final tree, because a file added and deleted again still stays in history once pushed.
#
#   scripts/check-committed-files.sh <rev-list arguments>
#   scripts/check-committed-files.sh origin/main..HEAD
#   scripts/check-committed-files.sh HEAD --not --remotes      # what the pre-push hook runs
#
# A file that genuinely belongs in the repo and trips a rule: change the rule here, in review.
# ----------------------------------------------------------------------------

set -euo pipefail

MAX_BYTES=$((2 * 1024 * 1024)) # the largest file tracked today is a 1.98 MB logo
# Local tool state: wrangler/miniflare stores, SQLite databases and their journals.
STATE_RE='(^|/)\.(wrangler|miniflare)/|\.(sqlite3?|db)(-wal|-shm|-journal)?$'
# The only binaries the repo has: images under assets/ and web/.
BINARY_OK_RE='^(assets|web)/.*\.(png|ico|jpe?g|webp|gif)$'

[[ $# -gt 0 ]] || { echo "usage: $0 <rev-list arguments, e.g. origin/main..HEAD>" >&2; exit 2; }

problems=()
commits=$(git rev-list --no-merges "$@")
for c in $commits; do
  short=$(git rev-parse --short "$c")
  # Added, copied, modified or renamed files; --numstat prints "-" for binaries. Gitlinks (submodules) skipped.
  while IFS=$'\t' read -r added _ path; do
    [[ -n "$path" ]] || continue
    [[ "$(git ls-tree "$c" -- "$path" | awk '{print $1}')" == 160000 ]] && continue
    if [[ "$path" =~ $STATE_RE ]]; then
      problems+=("$short $path: local tool state (a database or wrangler/miniflare store)")
    elif git check-ignore -q --no-index -- "$path"; then
      problems+=("$short $path: matches .gitignore (force-added?)")
    elif [[ "$added" == "-" && ! "$path" =~ $BINARY_OK_RE ]]; then
      problems+=("$short $path: binary file outside assets/ and web/ images")
    fi
    size=$(git cat-file -s "$c:$path")
    (( size <= MAX_BYTES )) || problems+=("$short $path: $size bytes, over the $MAX_BYTES-byte limit")
  done < <(git diff-tree -r --root --no-commit-id --no-renames --diff-filter=ACMR --numstat "$c")
done

if (( ${#problems[@]} )); then
  echo "❌ These commits add files that should not be in the repo's history:"
  printf '   %s\n' "${problems[@]}"
  echo "   Remove them from the commits (amend or rebase; a later deleting commit leaves them in history),"
  echo "   and add local state to .gitignore."
  exit 1
fi
echo "✅ $(wc -w <<< "$commits" | tr -d ' ') commit(s) checked: no local state, ignored, unexpected binary or oversized files."
