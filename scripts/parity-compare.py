#!/usr/bin/env python3
"""Parity comparator for the two cores (docs/apple-only-plan.md step 6).

Usage: parity-compare.py <rust-out> <swift-out>

Walks both output trees and compares them file by file:
- `.json`: parsed and compared value-by-value (serde_json vs JSONEncoder
  formatting may differ); RFC3339 timestamps, mark ids, and formatted dates
  normalize to placeholders; floats compare with an absolute tolerance of
  1e-9 (search scores).
- `.md` / `.txt`: byte-identical after the same normalization.
- everything else (source.epub, cover images): byte-identical.

Exits 0 when every file agrees, 1 otherwise (printing the first mismatches).
"""

import json
import re
import sys
from pathlib import Path

TS = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})")
MARK_ID = re.compile(r"id=[0-9a-hjkmnp-tv-z]{10}\b")
DATE = re.compile(
    r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2}, [0-9]{4}"
)

mismatches = []


def normalize(text):
    text = TS.sub("<TS>", text)
    text = MARK_ID.sub("id=<ID>", text)
    text = DATE.sub("<DATE>", text)
    return text


def normalize_string(value):
    return normalize(value)


def values_match(a, b, path):
    if isinstance(a, str) and isinstance(b, str):
        if normalize_string(a) != normalize_string(b):
            mismatches.append(f"{path}: {a!r} != {b!r}")
        return
    if isinstance(a, bool) or isinstance(b, bool):
        if a is not b:
            mismatches.append(f"{path}: {a!r} != {b!r}")
        return
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        if abs(float(a) - float(b)) > 1e-9:
            mismatches.append(f"{path}: {a!r} != {b!r}")
        return
    if a is None or b is None:
        if a is not b:
            mismatches.append(f"{path}: {a!r} != {b!r}")
        return
    if isinstance(a, dict) and isinstance(b, dict):
        if set(a.keys()) != set(b.keys()):
            mismatches.append(f"{path}: keys {sorted(a)} != {sorted(b)}")
            return
        for key in a:
            values_match(a[key], b[key], f"{path}.{key}")
        return
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            mismatches.append(f"{path}: list lengths {len(a)} != {len(b)}")
            return
        for index, (item_a, item_b) in enumerate(zip(a, b)):
            values_match(item_a, item_b, f"{path}[{index}]")
        return
    mismatches.append(f"{path}: incompatible types {type(a).__name__} != {type(b).__name__}")


def compare_json(a_path, b_path, rel):
    try:
        a = json.loads(a_path.read_text(encoding="utf-8"))
        b = json.loads(b_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        mismatches.append(f"{rel}: invalid JSON: {error}")
        return
    values_match(a, b, rel)


def compare_text(a_path, b_path, rel):
    a = normalize(a_path.read_text(encoding="utf-8"))
    b = normalize(b_path.read_text(encoding="utf-8"))
    if a != b:
        first = next(
            (i, line_a, line_b)
            for i, (line_a, line_b) in enumerate(zip(a.splitlines(), b.splitlines()))
            if line_a != line_b
        ) if len(a.splitlines()) == len(b.splitlines()) else (0, "", "")
        mismatches.append(f"{rel}: markdown differs (first differing line {first[0]})")
        for line_a, line_b in zip(a.splitlines(), b.splitlines()):
            if line_a != line_b:
                mismatches.append(f"  rust: {line_a!r}\n  swift: {line_b!r}")
                break


def compare_other(a_path, b_path, rel):
    if a_path.read_bytes() != b_path.read_bytes():
        mismatches.append(f"{rel}: binary content differs")


def tree(root):
    return {str(p.relative_to(root)) for p in root.rglob("*") if p.is_file()}


def main():
    rust, swift = Path(sys.argv[1]), Path(sys.argv[2])
    rust_files, swift_files = tree(rust), tree(swift)
    if rust_files != swift_files:
        for extra in sorted(rust_files - swift_files):
            mismatches.append(f"file only in rust output: {extra}")
        for missing in sorted(swift_files - rust_files):
            mismatches.append(f"file only in swift output: {missing}")

    for rel in sorted(rust_files & swift_files):
        a_path, b_path = rust / rel, swift / rel
        suffix = a_path.suffix
        if suffix == ".json":
            compare_json(a_path, b_path, rel)
        elif suffix in (".md", ".txt"):
            compare_text(a_path, b_path, rel)
        else:
            compare_other(a_path, b_path, rel)

    if mismatches:
        print(f"PARITY MISMATCH ({len(mismatches)} issues):")
        for line in mismatches[:40]:
            print(f"  {line}")
        sys.exit(1)
    print("parity clean")


if __name__ == "__main__":
    main()
