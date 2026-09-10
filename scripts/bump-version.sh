#!/bin/sh
# Single version source: bump the version everywhere, commit, and tag.
#
# Usage: scripts/bump-version.sh X.Y.Z
#
# Updates the root Cargo.toml [workspace.package] version (inherited by all
# crates), Cargo.lock, and the iOS MARKETING_VERSION; then creates the
# annotated tag vX.Y.Z on a dedicated "CHORE Bump version" commit.
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

tmp=$(mktemp)
sed 's/^version = ".*"$/version = "'"$version"'"/' Cargo.toml > "$tmp"
mv "$tmp" Cargo.toml

# iOS marketing version (both Debug and Release configs).
ios_proj="apple/ios/Margins.xcodeproj/project.pbxproj"
sed -E 's/^([[:space:]]*MARKETING_VERSION = ).*;$/\1'"$version"';/' "$ios_proj" > "$tmp"
mv "$tmp" "$ios_proj"

for file in Cargo.toml "$ios_proj"; do
  grep -q "MARKETING_VERSION = $version;" "$file" 2>/dev/null || grep -q "$version" "$file" || {
    echo "failed to update $file" >&2
    exit 1
  }
done

cargo update --workspace --quiet

git add Cargo.toml Cargo.lock "$ios_proj"
git commit -m "CHORE Bump version to $version"
git tag -a "v$version" -m "v$version"

echo "bumped to $version; push with: git push && git push origin v$version"
