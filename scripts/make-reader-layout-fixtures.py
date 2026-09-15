#!/usr/bin/env python3
"""Regenerate the macOS reader-layout test EPUBs.

Writes three small, fully redistributable EPUBs into
apple/Tests/MarginsModelTests/Fixtures/reader-layout/:

  reflowable.epub   five spine sections of uniquely identified paragraphs,
                    publisher typography, a large PNG plate, an internal
                    fragment link, and a short (odd) final section.
  rtl.epub          the same shape as a small right-to-left book.
  fixed-layout.epub a pre-paginated page that must never be treated as
                    reflowable two-column content.

Everything is built from this file with the standard library only; the
EPUBs are committed so `swift test` reads deterministic bytes without a
generation step. Run from the repo root:

    python3 scripts/make-reader-layout-fixtures.py

The ZIP entry timestamps are pinned so reruns are byte-identical.
"""

from __future__ import annotations

import pathlib
import struct
import zlib
import zipfile

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_DIR = REPO_ROOT / "apple" / "Tests" / "MarginsModelTests" / "Fixtures" / "reader-layout"

# Fixed DOS timestamp (2024-01-01 00:00:00) so reruns produce identical bytes.
ZIP_DATE_TIME = (2024, 1, 1, 0, 0, 0)

REF_LORES = 0  # color type 2 = truecolor; keep the byte small


def png_bytes(width: int, height: int) -> bytes:
    """A deterministic 3:2 raster image: two solid bands and a checkered
    center, enough for aspect-ratio assertions without pulling in Pillow."""

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type 0
        for x in range(width):
            if y < height // 3:
                pixel = (32, 64, 96)
            elif y > 2 * height // 3:
                pixel = (200, 190, 160)
            else:
                pixel = (240, 240, 240) if ((x // 40) + (y // 40)) % 2 == 0 else (120, 120, 120)
            raw.extend(pixel)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


CONTAINER = """<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"""

PUBLISHER_CSS = """/* Publisher sheet that deliberately pins body typography: the reader
   must override size/face without changing the column geometry contract. */
body {
  font-family: Georgia, "Times New Roman", serif;
  line-height: 1.5;
  margin: 0;
  padding: 0;
}
p {
  font-size: 1.05em;
  text-align: justify;
  margin: 0 0 1em 0;
  text-indent: 0;
}
h1 {
  font-size: 1.6em;
  margin: 0 0 1.2em 0;
}
img {
  display: block;
  margin: 1em auto;
}
a {
  color: #0645ad;
}
"""


def paragraph(section: int, index: int) -> str:
    return (
        f'<p id="p-{section}-{index:02d}">Paragraph {section}.{index:02d} of the '
        f"Margins reader-layout fixture. The quick brown fox jumps over the lazy dog "
        f"while uniquely numbered words keep the page detector honest.</p>"
    )


def chapter_xhtml(
    title: str,
    section: int,
    paragraphs: int,
    extra_head: str = "",
    extra_body: str = "",
    direction: str = "ltr",
) -> str:
    body = "\n".join(paragraph(section, index) for index in range(1, paragraphs + 1))
    if extra_body:
        body = body + "\n" + extra_body
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en" dir="{direction}">
<head>
  <meta charset="utf-8"/>
  <title>{title}</title>
  <link rel="stylesheet" type="text/css" href="css/publisher.css"/>
  {extra_head}
</head>
<body>
  <h1 id="heading-{section}">{title}</h1>
  {body}
</body>
</html>
"""


def nav_xhtml(title: str, entries: list[tuple[str, str]]) -> str:
    items = "\n".join(
        f'      <li><a href="{href}">{label}</a></li>' for label, href in entries
    )
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head>
  <meta charset="utf-8"/>
  <title>{title}</title>
</head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Contents</h1>
    <ol>
{items}
    </ol>
  </nav>
</body>
</html>
"""


def package_opf(
    title: str,
    identifier: str,
    manifest: list[tuple[str, str, str, str]],
    spine: list[str],
    extra_metadata: str = "",
    spine_attributes: str = "",
) -> str:
    items = "\n".join(
        f'    <item id="{item_id}" href="{href}" media-type="{media_type}"{properties}/>'
        for item_id, href, media_type, properties in manifest
    )
    refs = "\n".join(f'    <itemref idref="{idref}"/>' for idref in spine)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"
         xml:lang="en">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="bookid">{identifier}</dc:identifier>
    <dc:title>{title}</dc:title>
    <dc:language>en</dc:language>
    <dc:creator>Margins test fixtures</dc:creator>
    <meta property="dcterms:modified">2024-01-01T00:00:00Z</meta>
{extra_metadata}  </metadata>
  <manifest>
{items}
  </manifest>
  <spine{spine_attributes}>
{refs}
  </spine>
</package>
"""


def write_epub(path: pathlib.Path, entries: list[tuple[str, bytes]]) -> None:
    """mimetype first and stored; everything else deflated."""
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE_TIME)
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, data)


def build_reflowable() -> None:
    plate = png_bytes(900, 600)
    sections = {
        1: chapter_xhtml(
            "Chapter One",
            1,
            8,
            extra_body=(
                '<img id="plate" src="images/plate.png" alt="Fixture plate" width="900" height="600"/>'
                '\n  <p id="link-to-ch3">Continue with '
                '<a id="cross-link" href="ch3.xhtml#p-3-04">paragraph 3.04</a>.</p>'
            ),
        ),
        2: chapter_xhtml("Chapter Two", 2, 8),
        3: chapter_xhtml("Chapter Three", 3, 8),
        4: chapter_xhtml("Chapter Four", 4, 8),
        # The short final section is the odd final page.
        5: chapter_xhtml("Chapter Five", 5, 3),
    }
    manifest = [
        ("nav", "nav.xhtml", "application/xhtml+xml", ' properties="nav"'),
        ("css", "css/publisher.css", "text/css", ""),
        ("plate", "images/plate.png", "image/png", ""),
    ] + [
        (f"ch{section}", f"ch{section}.xhtml", "application/xhtml+xml", "")
        for section in sections
    ]
    entries: list[tuple[str, bytes]] = [
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", CONTAINER.encode()),
        (
            "OEBPS/content.opf",
            package_opf(
                "Margins Layout Fixture: Reflowable",
                "urn:uuid:margins-reader-layout-reflowable",
                manifest,
                [f"ch{section}" for section in sections],
            ).encode(),
        ),
        (
            "OEBPS/nav.xhtml",
            nav_xhtml(
                "Contents",
                [(f"Chapter {index}", f"ch{index}.xhtml") for index in sections],
            ).encode(),
        ),
        ("OEBPS/css/publisher.css", PUBLISHER_CSS.encode()),
        ("OEBPS/images/plate.png", plate),
    ]
    for section, xhtml in sections.items():
        entries.append((f"OEBPS/ch{section}.xhtml", xhtml.encode()))
    write_epub(OUT_DIR / "reflowable.epub", entries)


def build_rtl() -> None:
    sections = {
        1: chapter_xhtml("Chapter One", 1, 6, direction="rtl"),
        2: chapter_xhtml("Chapter Two", 2, 4, direction="rtl"),
    }
    manifest = [
        ("nav", "nav.xhtml", "application/xhtml+xml", ' properties="nav"'),
        ("css", "css/publisher.css", "text/css", ""),
    ] + [
        (f"ch{section}", f"ch{section}.xhtml", "application/xhtml+xml", "")
        for section in sections
    ]
    entries: list[tuple[str, bytes]] = [
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", CONTAINER.encode()),
        (
            "OEBPS/content.opf",
            package_opf(
                "Margins Layout Fixture: RTL",
                "urn:uuid:margins-reader-layout-rtl",
                manifest,
                [f"ch{section}" for section in sections],
                spine_attributes=' page-progression-direction="rtl"',
            ).encode(),
        ),
        (
            "OEBPS/nav.xhtml",
            nav_xhtml(
                "Contents",
                [(f"Chapter {index}", f"ch{index}.xhtml") for index in sections],
            ).encode(),
        ),
        ("OEBPS/css/publisher.css", PUBLISHER_CSS.encode()),
    ]
    for section, xhtml in sections.items():
        entries.append((f"OEBPS/ch{section}.xhtml", xhtml.encode()))
    write_epub(OUT_DIR / "rtl.epub", entries)


def build_fixed_layout() -> None:
    page = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
<head>
  <meta charset="utf-8"/>
  <title>Fixed Page One</title>
  <meta name="viewport" content="width=1024, height=768"/>
  <style>
    html, body { margin: 0; padding: 0; width: 1024px; height: 768px; overflow: hidden; }
    h1 { position: absolute; top: 64px; left: 64px; font: 48px Georgia, serif; }
    p { position: absolute; top: 160px; left: 64px; width: 896px; font: 24px Georgia, serif; }
  </style>
</head>
<body>
  <h1 id="heading-1">Fixed Page One</h1>
  <p id="p-1-01">A pre-paginated page with publisher-pinned geometry. It must keep its aspect ratio and stay single-page.</p>
</body>
</html>
"""
    page_two = page.replace("One", "Two").replace("p-1-01", "p-2-01")
    manifest = [
        ("nav", "nav.xhtml", "application/xhtml+xml", ' properties="nav"'),
        ("page1", "page1.xhtml", "application/xhtml+xml", ""),
        ("page2", "page2.xhtml", "application/xhtml+xml", ""),
    ]
    entries: list[tuple[str, bytes]] = [
        ("mimetype", b"application/epub+zip"),
        ("META-INF/container.xml", CONTAINER.encode()),
        (
            "OEBPS/content.opf",
            package_opf(
                "Margins Layout Fixture: Fixed",
                "urn:uuid:margins-reader-layout-fixed",
                manifest,
                ["page1", "page2"],
                extra_metadata=(
                    '    <meta property="rendition:layout">pre-paginated</meta>\n'
                    '    <meta property="rendition:orientation">landscape</meta>\n'
                    '    <meta property="rendition:spread">none</meta>\n'
                ),
            ).encode(),
        ),
        (
            "OEBPS/nav.xhtml",
            nav_xhtml("Contents", [("Page One", "page1.xhtml"), ("Page Two", "page2.xhtml")]).encode(),
        ),
        ("OEBPS/page1.xhtml", page.encode()),
        ("OEBPS/page2.xhtml", page_two.encode()),
    ]
    write_epub(OUT_DIR / "fixed-layout.epub", entries)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    build_reflowable()
    build_rtl()
    build_fixed_layout()
    for name in ("reflowable.epub", "rtl.epub", "fixed-layout.epub"):
        path = OUT_DIR / name
        print(f"wrote {path.relative_to(REPO_ROOT)} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
