#!/bin/sh
# Re-vendor the reader's JS dependencies and bundled fonts. The repo has no
# Node toolchain, so the versions that package.json used to pin are locked
# in here.
#
# Pinned versions (verified by sha256 before anything is copied):
#   epubjs 0.3.93  https://unpkg.com/epubjs@0.3.93/dist/epub.min.js
#     sha256 06eae15745107b4aa508c95538275251f69bfb9f1175621fc458d9f42ed082d4
#   jszip 3.10.1   https://unpkg.com/jszip@3.10.1/dist/jszip.min.js
#     sha256 acc7e41455a80765b5fd9c7ee1b8078a6d160bbbca455aeae854de65c947d59e
#   Atkinson Hyperlegible Next (SIL OFL 1.1), google/fonts @
#   95f4904fc8bcf26d3420fe315560c96417c6dec7
#     https://raw.githubusercontent.com/google/fonts/95f4904fc8bcf26d3420fe315560c96417c6dec7/ofl/atkinsonhyperlegiblenext/AtkinsonHyperlegibleNext[wght].ttf
#       sha256 5a455d1cfa099b601ab70751bb9673e8fe1854dc4500c80e1a220d0d75e31745
#     https://raw.githubusercontent.com/google/fonts/95f4904fc8bcf26d3420fe315560c96417c6dec7/ofl/atkinsonhyperlegiblenext/AtkinsonHyperlegibleNext-Italic[wght].ttf
#       sha256 ce9cffed32742ad2d9238c561a93220385e5934cdc02b8eb4097a50efa957dc6
#     https://raw.githubusercontent.com/google/fonts/95f4904fc8bcf26d3420fe315560c96417c6dec7/ofl/atkinsonhyperlegiblenext/OFL.txt
#       sha256 aca6a428580965d2297d1b718042dd427c2a9443ece3b0d02d758e161e0c4030
#
# The font files are copied renamed — the upstream `[wght]` brackets would
# percent-encode in URLs and `ReaderResource` rejects `%`. Bytes are
# unmodified (no subsetting).
#
# Usage: scripts/vendor-reader.sh
set -eu

EPUBJS_VERSION=0.3.93
EPUBJS_SHA256=06eae15745107b4aa508c95538275251f69bfb9f1175621fc458d9f42ed082d4
JSZIP_VERSION=3.10.1
JSZIP_SHA256=acc7e41455a80765b5fd9c7ee1b8078a6d160bbbca455aeae854de65c947d59e
FONTS_SHA=95f4904fc8bcf26d3420fe315560c96417c6dec7
AHN_SHA256=5a455d1cfa099b601ab70751bb9673e8fe1854dc4500c80e1a220d0d75e31745
AHN_ITALIC_SHA256=ce9cffed32742ad2d9238c561a93220385e5934cdc02b8eb4097a50efa957dc6
AHN_OFL_SHA256=aca6a428580965d2297d1b718042dd427c2a9443ece3b0d02d758e161e0c4030

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

fonts_base="https://raw.githubusercontent.com/google/fonts/$FONTS_SHA/ofl/atkinsonhyperlegiblenext"

fetch "https://unpkg.com/epubjs@$EPUBJS_VERSION/dist/epub.min.js" \
  "$EPUBJS_SHA256" epub.min.js
fetch "https://unpkg.com/jszip@$JSZIP_VERSION/dist/jszip.min.js" \
  "$JSZIP_SHA256" jszip.min.js
fetch "$fonts_base/AtkinsonHyperlegibleNext%5Bwght%5D.ttf" \
  "$AHN_SHA256" AtkinsonHyperlegibleNext.ttf
fetch "$fonts_base/AtkinsonHyperlegibleNext-Italic%5Bwght%5D.ttf" \
  "$AHN_ITALIC_SHA256" AtkinsonHyperlegibleNext-Italic.ttf
fetch "$fonts_base/OFL.txt" \
  "$AHN_OFL_SHA256" AtkinsonHyperlegibleNext-OFL.txt

cp "$tmp/epub.min.js" "$tmp/jszip.min.js" \
  "$tmp/AtkinsonHyperlegibleNext.ttf" "$tmp/AtkinsonHyperlegibleNext-Italic.ttf" \
  "$tmp/AtkinsonHyperlegibleNext-OFL.txt" "$dest/"
echo "vendored epubjs $EPUBJS_VERSION, jszip $JSZIP_VERSION, and Atkinson Hyperlegible Next into $dest"
