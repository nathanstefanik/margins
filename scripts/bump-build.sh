#!/bin/sh
# Bump the iOS build number (CURRENT_PROJECT_VERSION) for a TestFlight/App
# Store upload. TestFlight rejects reused build numbers, so this is bumped
# once per upload — deliberately NOT touched by scripts/bump-version.sh,
# which only moves MARKETING_VERSION.
#
# Usage:
#   scripts/bump-build.sh        # increment current build number by 1
#   scripts/bump-build.sh N      # set an explicit build number
#
# Edits both the Debug and Release configs in the iOS pbxproj. Does not
# commit; the archive upload path leaves the result visible in git status.
set -eu

usage() {
  echo "usage: $0 [N]" >&2
  exit 1
}

proj="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/apple/ios/Margins.xcodeproj/project.pbxproj"
key='CURRENT_PROJECT_VERSION'

current=$(grep -m1 -E "^[[:space:]]*$key = [0-9]+;" "$proj" | grep -oE '[0-9]+')
[ -n "$current" ] || { echo "no $key found in pbxproj" >&2; exit 1; }

if [ $# -eq 0 ]; then
  next=$((current + 1))
elif [ $# -eq 1 ] && [ "$1" -gt 0 ] 2>/dev/null; then
  next="$1"
else
  usage
fi

tmp=$(mktemp)
sed -E "s/^([[:space:]]*$key = )[0-9]+;$/\1$next;/" "$proj" > "$tmp"
mv "$tmp" "$proj"

count=$(grep -cE "^[[:space:]]*$key = $next;" "$proj")
[ "$count" -eq 2 ] || { echo "expected 2 $key entries, found $count" >&2; exit 1; }

echo "$key: $current -> $next (remember to commit before archiving)"
