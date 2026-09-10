#!/bin/sh
# Re-vendor the reader's JS dependencies. The repo has no Node toolchain,
# so the versions that package.json used to pin are locked in here.
#
# Pinned versions (verified by sha256 before anything is copied):
#   epubjs 0.3.93  https://unpkg.com/epubjs@0.3.93/dist/epub.min.js
#     sha256 06eae15745107b4aa508c95538275251f69bfb9f1175621fc458d9f42ed082d4
#   jszip 3.10.1   https://unpkg.com/jszip@3.10.1/dist/jszip.min.js
#     sha256 acc7e41455a80765b5fd9c7ee1b8078a6d160bbbca455aeae854de65c947d59e
#
# Usage: scripts/vendor-reader.sh
set -eu

EPUBJS_VERSION=0.3.93
EPUBJS_SHA256=06eae15745107b4aa508c95538275251f69bfb9f1175621fc458d9f42ed082d4
JSZIP_VERSION=3.10.1
JSZIP_SHA256=acc7e41455a80765b5fd9c7ee1b8078a6d160bbbca455aeae854de65c947d59e

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dest="$root/apple/Sources/MarginsModel/Resources/reader"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fetch() {
  url="$1"
  want="$2"
  out="$3"
  echo "fetching $url"
  curl -fsSL -o "$tmp/$out" "$url"
  echo "$want  $tmp/$out" | shasum -a 256 -c - >/dev/null
}

fetch "https://unpkg.com/epubjs@$EPUBJS_VERSION/dist/epub.min.js" \
  "$EPUBJS_SHA256" epub.min.js
fetch "https://unpkg.com/jszip@$JSZIP_VERSION/dist/jszip.min.js" \
  "$JSZIP_SHA256" jszip.min.js

cp "$tmp/epub.min.js" "$tmp/jszip.min.js" "$dest/"
echo "vendored epubjs $EPUBJS_VERSION and jszip $JSZIP_VERSION into $dest"
