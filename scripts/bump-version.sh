#!/bin/sh
# Single version source: apple/VERSION. Bump it everywhere, commit, tag.
#
# Usage: scripts/bump-version.sh X.Y.Z
#
# Writes apple/VERSION (the source make-app.sh reads and release.yml's tag
# check verifies) and the iOS MARKETING_VERSION (both configs); then creates
# the annotated tag vX.Y.Z on a dedicated "CHORE Bump version" commit.
#
# CURRENT_PROJECT_VERSION (the TestFlight build number) is deliberately
# NOT touched here: TestFlight rejects reused build numbers, so it is a
# manual integer bumped by the upload path, not by version tags.
set -eu

usage() {
  echo "usage: $0 X.Y.Z" >&2
  exit 1
}

[ $# -eq 1 ] || usage
version="$1"
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || usage

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

printf '%s\n' "$version" > apple/VERSION

# iOS marketing version (both Debug and Release configs).
ios_proj="apple/ios/Margins.xcodeproj/project.pbxproj"
tmp=$(mktemp)
sed -E 's/^([[:space:]]*MARKETING_VERSION = ).*;$/\1'"$version"';/' "$ios_proj" > "$tmp"
mv "$tmp" "$ios_proj"

grep -q "MARKETING_VERSION = $version;" "$ios_proj" || {
  echo "failed to update $ios_proj" >&2
  exit 1
}

git add apple/VERSION "$ios_proj"
git commit -m "CHORE Bump version to $version"
git tag -a "v$version" -m "v$version"

echo "bumped to $version; push with: git push && git push origin v$version"
