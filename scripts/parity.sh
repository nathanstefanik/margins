#!/bin/sh
# Parity harness (docs/apple-only-plan.md Phase 2 step 6) — the deletion
# gate: proves the Swift core and the Rust core produce identical trees,
# renders, catalogs, and search results for the same scripted sequence.
# Kept until the Rust code is deleted (step 7), then removed.
#
# Usage: scripts/parity.sh [extra-epub ...]
#   Runs the sequence for every fixtures/*.epub, for any extra EPUBs passed
#   as arguments (a local EPUB3 not committed, for instance), and for the
#   Rust-written sample library at fixtures/parity-library/.
#
# Artifacts land in build/parity/ (gitignored): per-run snapshot trees and
# reports for each core, so a mismatch can be inspected by hand.

set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

out="${PARITY_OUT:-build/parity}"
rm -rf "$out"
mkdir -p "$out/work"

echo "==> building the Rust parity driver"
cargo build --example parity --manifest-path "$root/Cargo.toml" --quiet
rust_driver="$root/target/debug/examples/parity"

echo "==> building the Swift parity driver"
swift build --package-path apple --product parity --quiet
swift_driver="$root/apple/.build/debug/parity"

run_pair() {
    name="$1"
    fixture="$2" # empty for library mode

    echo "==> parity: $name"
    rust_lib="$out/work/$name-rust"
    swift_lib="$out/work/$name-swift"

    if [ -n "$fixture" ]; then
        "$rust_driver" --library "$rust_lib" --out "$out/$name-rust" --fixture "$fixture"
        "$swift_driver" --library "$swift_lib" --out "$out/$name-swift" --fixture "$fixture"
    else
        cp -R "$root/fixtures/parity-library" "$rust_lib"
        cp -R "$root/fixtures/parity-library" "$swift_lib"
        "$rust_driver" --library "$rust_lib" --out "$out/$name-rust"
        "$swift_driver" --library "$swift_lib" --out "$out/$name-swift"
    fi

    python3 "$root/scripts/parity-compare.py" "$out/$name-rust" "$out/$name-swift"
}

for epub in "$root"/fixtures/*.epub "$@"; do
    [ -f "$epub" ] || continue
    run_pair "$(basename "$epub" .epub)" "$epub"
done

if [ -d "$root/fixtures/parity-library" ]; then
    # The Rust-written sample library: the Swift core must open it as-is
    # and produce identical results (read-path compatibility).
    run_pair "parity-library" ""
fi

echo "==> all parity runs clean"
