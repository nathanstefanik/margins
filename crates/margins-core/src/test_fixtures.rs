//! Shared fixtures for unit tests. Not used in production builds.

use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// Which cover declaration the sample EPUB should carry.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SampleCover {
    /// No cover at all.
    None,
    /// EPUB3: manifest item with `properties="cover-image"`.
    Epub3,
    /// EPUB2: `<meta name="cover" content="..."/>` pointing at the item.
    Epub2,
    /// No cover marker: only an image item in the manifest (fallback path).
    BareImage,
}

/// Which table of contents the sample EPUB should carry. The labels
/// deliberately differ from the chapters' `<title>` tags so a test can tell
/// which source a title came from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SampleToc {
    /// No nav document and no NCX.
    None,
    /// EPUB2 NCX, with a nested navPoint and an entry for a non-spine file.
    Ncx,
    /// EPUB3 nav document, with a decoy `landmarks` nav before the TOC.
    Nav,
}

/// A valid 1x1 PNG (red pixel), small enough to embed in tests.
pub const SAMPLE_COVER_PNG: &[u8] = &[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
    0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D, 0xB0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
    0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// Build a minimal valid-enough EPUB with two chapters under `dir`.
pub fn write_sample_epub(dir: &Path, filename: &str) -> PathBuf {
    write_sample_epub_covered(dir, filename, SampleCover::None)
}

/// Build the sample EPUB with the requested cover declaration.
pub fn write_sample_epub_covered(dir: &Path, filename: &str, cover: SampleCover) -> PathBuf {
    write_sample_epub_full(dir, filename, cover, SampleToc::None)
}

/// Build the sample EPUB with the requested table of contents.
pub fn write_sample_epub_toc(dir: &Path, filename: &str, toc: SampleToc) -> PathBuf {
    write_sample_epub_full(dir, filename, SampleCover::None, toc)
}

/// Build the sample EPUB with both a cover declaration and a TOC.
pub fn write_sample_epub_full(
    dir: &Path,
    filename: &str,
    cover: SampleCover,
    toc: SampleToc,
) -> PathBuf {
    let path = dir.join(filename);
    let file = File::create(&path).expect("create epub");
    let mut zip = ZipWriter::new(file);
    let stored = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    let deflated =
        SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    zip.start_file("mimetype", stored).unwrap();
    zip.write_all(b"application/epub+zip").unwrap();

    zip.start_file("META-INF/container.xml", deflated).unwrap();
    zip.write_all(
        br#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#,
    )
    .unwrap();

    let cover_item = match cover {
        SampleCover::None => "",
        SampleCover::Epub3 => {
            r#"    <item href="cover.png" id="cover" media-type="image/png" properties="cover-image"/>
"#
        }
        SampleCover::Epub2 | SampleCover::BareImage => {
            r#"    <item href="cover.png" id="cover" media-type="image/png"/>
"#
        }
    };
    let cover_meta = match cover {
        SampleCover::Epub2 => {
            r#"    <meta name="cover" content="cover"/>
"#
        }
        _ => "",
    };

    let toc_item = match toc {
        SampleToc::None => "",
        SampleToc::Ncx => {
            r#"    <item href="toc.ncx" id="ncx" media-type="application/x-dtbncx+xml"/>
"#
        }
        SampleToc::Nav => {
            r#"    <item href="nav.xhtml" id="nav" media-type="application/xhtml+xml" properties="nav"/>
"#
        }
    };
    let spine_toc = match toc {
        SampleToc::Ncx => r#" toc="ncx""#,
        _ => "",
    };

    zip.start_file("OEBPS/content.opf", deflated).unwrap();
    zip.write_all(
        format!(
            r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Sample Book</dc:title>
    <dc:creator>Test Author</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">urn:margins:test</dc:identifier>
{cover_meta}  </metadata>
  <manifest>
    <item href="chapter1.xhtml" id="c1" media-type="application/xhtml+xml"/>
    <item id="c2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
{cover_item}{toc_item}  </manifest>
  <spine{spine_toc}>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
  </spine>
</package>"#
        )
        .as_bytes(),
    )
    .unwrap();

    zip.start_file("OEBPS/chapter1.xhtml", deflated).unwrap();
    zip.write_all(
        br#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Introduction</title></head>
<body><p>Hello chapter one.</p></body>
</html>"#,
    )
    .unwrap();

    zip.start_file("OEBPS/chapter2.xhtml", deflated).unwrap();
    zip.write_all(
        br#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>The Market</title></head>
<body><p>Hello chapter two.</p></body>
</html>"#,
    )
    .unwrap();

    match toc {
        SampleToc::None => {}
        SampleToc::Ncx => {
            zip.start_file("OEBPS/toc.ncx", deflated).unwrap();
            // `np-2` reverses the attribute order and the last entry points
            // at a file that is not in the spine: both are ignored cleanly.
            zip.write_all(
                br#"<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="np-1" playOrder="1">
      <navLabel><text>Opening Remarks</text></navLabel>
      <content src="chapter1.xhtml#start"/>
      <navPoint playOrder="2" id="np-2">
        <navLabel><text>A Nested Aside</text></navLabel>
        <content src="chapter1.xhtml#aside"/>
      </navPoint>
    </navPoint>
    <navPoint id="np-3" playOrder="3">
      <navLabel><text>Market Day</text></navLabel>
      <content src="chapter2.xhtml"/>
    </navPoint>
    <navPoint id="np-4" playOrder="4">
      <navLabel><text>Colophon</text></navLabel>
      <content src="colophon.xhtml#end"/>
    </navPoint>
  </navMap>
</ncx>"#,
            )
            .unwrap();
        }
        SampleToc::Nav => {
            zip.start_file("OEBPS/nav.xhtml", deflated).unwrap();
            // The `landmarks` nav comes first on purpose: only the one
            // marked `toc` may drive the titles.
            zip.write_all(
                br#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><title>Contents</title></head>
<body>
  <nav epub:type="landmarks">
    <ol><li><a href="chapter1.xhtml">Start Reading</a></li></ol>
  </nav>
  <nav epub:type="toc" role="doc-toc">
    <ol>
      <li><a href="chapter1.xhtml#start">Opening <em>Remarks</em></a>
        <ol><li><a href="chapter1.xhtml#aside">A Nested Aside</a></li></ol>
      </li>
      <li><a href="chapter2.xhtml">Market Day</a></li>
      <li><a href="colophon.xhtml#end">Colophon</a></li>
    </ol>
  </nav>
</body>
</html>"#,
            )
            .unwrap();
        }
    }

    if cover != SampleCover::None {
        zip.start_file("OEBPS/cover.png", deflated).unwrap();
        zip.write_all(SAMPLE_COVER_PNG).unwrap();
    }

    zip.finish().unwrap();
    path
}

/// Builds an EPUB whose chapters carry exactly the given `<title>` and
/// first-heading text (either may be empty to omit the tag) and no TOC, for
/// exercising the title fallback chain.
pub fn write_epub_with_titles(
    dir: &Path,
    filename: &str,
    book_title: &str,
    chapters: &[(&str, &str)],
) -> PathBuf {
    let path = dir.join(filename);
    let file = File::create(&path).expect("create epub");
    let mut zip = ZipWriter::new(file);
    let stored = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    let deflated =
        SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    zip.start_file("mimetype", stored).unwrap();
    zip.write_all(b"application/epub+zip").unwrap();

    zip.start_file("META-INF/container.xml", deflated).unwrap();
    zip.write_all(
        br#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#,
    )
    .unwrap();

    let manifest: String = (0..chapters.len())
        .map(|i| {
            format!(
                "    <item href=\"ch{i}.xhtml\" id=\"c{i}\" media-type=\"application/xhtml+xml\"/>\n"
            )
        })
        .collect();
    let spine: String = (0..chapters.len())
        .map(|i| format!("    <itemref idref=\"c{i}\"/>\n"))
        .collect();

    zip.start_file("OEBPS/content.opf", deflated).unwrap();
    zip.write_all(
        format!(
            r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{book_title}</dc:title>
    <dc:creator>Test Author</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="uid">urn:margins:test</dc:identifier>
  </metadata>
  <manifest>
{manifest}  </manifest>
  <spine>
{spine}  </spine>
</package>"#
        )
        .as_bytes(),
    )
    .unwrap();

    for (index, (document_title, heading)) in chapters.iter().enumerate() {
        let title_tag = if document_title.is_empty() {
            String::new()
        } else {
            format!("<title>{document_title}</title>")
        };
        let heading_tag = if heading.is_empty() {
            String::new()
        } else {
            format!("<h2>{heading}</h2>")
        };
        zip.start_file(format!("OEBPS/ch{index}.xhtml"), deflated)
            .unwrap();
        zip.write_all(
            format!(
                r#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>{title_tag}</head>
<body>{heading_tag}<p>Body text.</p></body>
</html>"#
            )
            .as_bytes(),
        )
        .unwrap();
    }

    zip.finish().unwrap();
    path
}
