#!/bin/sh
# Single version source: bump the version everywhere, commit, and tag.
#
# Usage: scripts/bump-version.sh X.Y.Z
#
# Updates package.json, package-lock.json, src-tauri/tauri.conf.json, the
# root Cargo.toml [workspace.package] version (inherited by all crates),
# and Cargo.lock; then creates the annotated tag vX.Y.Z on a dedicated
# "CHORE Bump version" commit.
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

node -e '
  const fs = require("fs");
  const version = process.argv[1];

  const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
  pkg.version = version;
  fs.writeFileSync("package.json", JSON.stringify(pkg, null, 2) + "\n");

  const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8"));
  lock.version = version;
  lock.packages[""].version = version;
  fs.writeFileSync("package-lock.json", JSON.stringify(lock, null, 2) + "\n");

  const tauri = JSON.parse(fs.readFileSync("src-tauri/tauri.conf.json", "utf8"));
  tauri.version = version;
  fs.writeFileSync("src-tauri/tauri.conf.json", JSON.stringify(tauri, null, 2) + "\n");
' "$version"

tmp=$(mktemp)
sed 's/^version = ".*"$/version = "'"$version"'"/' Cargo.toml > "$tmp"
mv "$tmp" Cargo.toml

for file in Cargo.toml package.json src-tauri/tauri.conf.json; do
  grep -q "$version" "$file" || {
    echo "failed to update $file" >&2
    exit 1
  }
done

cargo update --workspace --quiet

git add Cargo.toml Cargo.lock package.json package-lock.json src-tauri/tauri.conf.json
git commit -m "CHORE Bump version to $version"
git tag -a "v$version" -m "v$version"

echo "bumped to $version; push with: git push && git push origin v$version"
