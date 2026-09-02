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
{cover_item}  </manifest>
  <spine>
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

    if cover != SampleCover::None {
        zip.start_file("OEBPS/cover.png", deflated).unwrap();
        zip.write_all(SAMPLE_COVER_PNG).unwrap();
    }

    zip.finish().unwrap();
    path
}
