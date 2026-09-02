use crate::models::ChapterMeta;
use quick_xml::events::Event;
use quick_xml::Reader;
use regex::Regex;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;
use thiserror::Error;
use zip::ZipArchive;

#[derive(Debug, Error)]
pub enum EpubError {
    #[error("zip error: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("xml error: {0}")]
    Xml(String),
    #[error("invalid epub: {0}")]
    Invalid(String),
}

#[derive(Debug, Clone)]
pub struct EpubInfo {
    pub title: String,
    pub author: String,
    pub language: Option<String>,
    pub chapters: Vec<ChapterMeta>,
    pub cover: Option<CoverImage>,
}

/// A cover image extracted from the EPUB: raw bytes plus the file extension
/// to store it under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverImage {
    pub bytes: Vec<u8>,
    pub extension: &'static str,
}

pub fn parse_epub(path: &Path) -> Result<EpubInfo, EpubError> {
    let file = File::open(path)?;
    let reader = BufReader::new(file);
    let mut archive = ZipArchive::new(reader)?;

    let container = read_zip_text(&mut archive, "META-INF/container.xml")?;
    let opf_path = find_opf_path(&container)?;
    let opf = read_zip_text(&mut archive, &opf_path)?;
    let opf_dir = Path::new(&opf_path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();

    let metadata = parse_opf_metadata(&opf)?;
    let manifest = parse_manifest(&opf)?;
    let spine = parse_spine(&opf)?;
    let cover = extract_cover(&mut archive, &opf, &opf_dir);

    let mut chapters = Vec::new();
    for (index, idref) in spine.iter().enumerate() {
        let Some(href) = manifest.get(idref) else {
            continue;
        };
        if !is_probably_content(href) {
            continue;
        }
        let full_href = join_href(&opf_dir, href);
        let title = title_from_href(&mut archive, &full_href)
            .unwrap_or_else(|| format!("Chapter {}", index + 1));
        let key = format!("{:03}", index + 1);
        chapters.push(ChapterMeta {
            key,
            index,
            title,
            href: full_href,
        });
    }

    if chapters.is_empty() {
        return Err(EpubError::Invalid("no readable chapters found".into()));
    }

    Ok(EpubInfo {
        title: metadata.title,
        author: metadata.author,
        language: metadata.language,
        chapters,
        cover,
    })
}

/// Extracts a cover image from an EPUB file on disk without parsing the full
/// spine. Used by the library backfill for books imported before covers were
/// extracted. Returns `None` when the book has no (readable) cover.
pub fn extract_cover_from_epub(path: &Path) -> Option<CoverImage> {
    let file = File::open(path).ok()?;
    let mut archive = ZipArchive::new(BufReader::new(file)).ok()?;
    let container = read_zip_text(&mut archive, "META-INF/container.xml").ok()?;
    let opf_path = find_opf_path(&container).ok()?;
    let opf = read_zip_text(&mut archive, &opf_path).ok()?;
    let opf_dir = Path::new(&opf_path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    extract_cover(&mut archive, &opf, &opf_dir)
}

/// Cover resolution order: EPUB3 `properties="cover-image"`, EPUB2
/// `<meta name="cover" content="id">`, then the first manifest item with an
/// image media type. Absent or unreadable covers yield `None` — extraction
/// must never fail an import.
fn extract_cover(
    archive: &mut ZipArchive<BufReader<File>>,
    opf: &str,
    opf_dir: &str,
) -> Option<CoverImage> {
    let items = parse_manifest_items(opf).ok()?;
    let mut candidates: Vec<&ManifestItem> = Vec::new();

    if let Some(item) = items.iter().find(|item| {
        item.properties
            .as_deref()
            .is_some_and(|properties| properties.split_whitespace().any(|p| p == "cover-image"))
    }) {
        candidates.push(item);
    }

    if let Some(id) = cover_meta_id(opf) {
        if let Some(item) = items.iter().find(|item| item.id == id) {
            candidates.push(item);
        }
    }

    if let Some(item) = items.iter().find(|item| {
        item.media_type
            .as_deref()
            .is_some_and(|m| m.starts_with("image/"))
    }) {
        candidates.push(item);
    }

    for item in candidates {
        let Some(media_type) = item.media_type.as_deref() else {
            continue;
        };
        let Some(extension) = extension_for_media_type(media_type) else {
            continue;
        };
        let full_href = join_href(opf_dir, &item.href);
        if let Ok(mut file) = archive.by_name(&full_href) {
            let mut bytes = Vec::new();
            if file.read_to_end(&mut bytes).is_ok() && !bytes.is_empty() {
                return Some(CoverImage { bytes, extension });
            }
        }
    }

    None
}

fn extension_for_media_type(media_type: &str) -> Option<&'static str> {
    match media_type.to_lowercase().as_str() {
        "image/jpeg" | "image/jpg" => Some("jpg"),
        "image/png" => Some("png"),
        "image/gif" => Some("gif"),
        "image/svg+xml" => Some("svg"),
        "image/webp" => Some("webp"),
        _ => None,
    }
}

/// EPUB2 cover pointer: `<meta name="cover" content="manifest-id"/>`. The
/// attributes may appear in either order.
fn cover_meta_id(opf: &str) -> Option<String> {
    let re = Regex::new(
        r#"<meta\s+[^>]*?(?:name="cover"[^>]*?content="([^"]*)"|content="([^"]*)"[^>]*?name="cover")"#,
    )
    .ok()?;
    re.captures(opf).and_then(|captures| {
        captures
            .get(1)
            .or_else(|| captures.get(2))
            .map(|m| m.as_str().to_string())
            .filter(|s| !s.is_empty())
    })
}

struct Metadata {
    title: String,
    author: String,
    language: Option<String>,
}

fn read_zip_text(
    archive: &mut ZipArchive<BufReader<File>>,
    path: &str,
) -> Result<String, EpubError> {
    let mut file = archive.by_name(path)?;
    let mut buf = String::new();
    file.read_to_string(&mut buf)?;
    Ok(buf)
}

fn find_opf_path(container_xml: &str) -> Result<String, EpubError> {
    let re = Regex::new(r#"full-path="([^"]+)""#).unwrap();
    re.captures(container_xml)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
        .ok_or_else(|| EpubError::Invalid("OPF path not found in container.xml".into()))
}

fn parse_opf_metadata(opf: &str) -> Result<Metadata, EpubError> {
    let mut reader = Reader::from_str(opf);
    reader.config_mut().trim_text(true);

    let mut title = "Untitled".to_string();
    let mut author = "Unknown".to_string();
    let mut language = None;
    let mut in_metadata = false;
    let mut current_tag = String::new();

    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                let name = String::from_utf8_lossy(e.name().as_ref()).to_string();
                if name == "metadata" {
                    in_metadata = true;
                }
                if in_metadata {
                    current_tag = name;
                }
            }
            Ok(Event::Text(e)) => {
                if !in_metadata {
                    continue;
                }
                let text = e
                    .unescape()
                    .map_err(|err| EpubError::Xml(err.to_string()))?;
                match current_tag.as_str() {
                    "dc:title" | "title" => title = text.into_owned(),
                    "dc:creator" | "creator" => author = text.into_owned(),
                    "dc:language" | "language" => language = Some(text.into_owned()),
                    _ => {}
                }
            }
            Ok(Event::End(e)) => {
                let name_bytes = e.name().as_ref().to_vec();
                let name = String::from_utf8_lossy(&name_bytes);
                if name == "metadata" {
                    in_metadata = false;
                }
                current_tag.clear();
            }
            Ok(Event::Eof) => break,
            Err(err) => return Err(EpubError::Xml(err.to_string())),
            _ => {}
        }
    }

    Ok(Metadata {
        title,
        author,
        language,
    })
}

struct ManifestItem {
    id: String,
    href: String,
    media_type: Option<String>,
    properties: Option<String>,
}

fn parse_manifest_items(opf: &str) -> Result<Vec<ManifestItem>, EpubError> {
    let mut items = Vec::new();

    let mut reader = Reader::from_str(opf);
    reader.config_mut().trim_text(true);
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element))
                if element.local_name().as_ref() == b"item" =>
            {
                let mut id = None;
                let mut href = None;
                let mut media_type = None;
                let mut properties = None;

                for attribute in element.attributes() {
                    let attribute = attribute.map_err(|err| EpubError::Xml(err.to_string()))?;
                    let value = attribute
                        .decode_and_unescape_value(reader.decoder())
                        .map_err(|err| EpubError::Xml(err.to_string()))?
                        .into_owned();

                    match attribute.key.local_name().as_ref() {
                        b"id" => id = Some(value),
                        b"href" => href = Some(value),
                        b"media-type" => media_type = Some(value),
                        b"properties" => properties = Some(value),
                        _ => {}
                    }
                }

                if let (Some(id), Some(href)) = (id, href) {
                    items.push(ManifestItem {
                        id,
                        href,
                        media_type,
                        properties,
                    });
                }
            }
            Ok(Event::Eof) => break,
            Err(err) => return Err(EpubError::Xml(err.to_string())),
            _ => {}
        }
    }

    Ok(items)
}

fn parse_manifest(opf: &str) -> Result<std::collections::HashMap<String, String>, EpubError> {
    Ok(parse_manifest_items(opf)?
        .into_iter()
        .map(|item| (item.id, item.href))
        .collect())
}

fn parse_spine(opf: &str) -> Result<Vec<String>, EpubError> {
    let re = Regex::new(r#"<itemref\s+[^>]*idref="([^"]+)""#).unwrap();
    Ok(re
        .captures_iter(opf)
        .map(|cap| cap.get(1).unwrap().as_str().to_string())
        .collect())
}

fn is_probably_content(href: &str) -> bool {
    let lower = href.to_lowercase();
    !(lower.ends_with(".ncx")
        || lower.contains("toc")
        || lower.contains("nav")
        || lower.ends_with(".css")
        || lower.ends_with(".jpg")
        || lower.ends_with(".jpeg")
        || lower.ends_with(".png")
        || lower.ends_with(".gif")
        || lower.ends_with(".svg"))
}

fn join_href(base_dir: &str, href: &str) -> String {
    if base_dir.is_empty() {
        return href.to_string();
    }
    format!(
        "{}/{}",
        base_dir.trim_end_matches('/'),
        href.trim_start_matches('/')
    )
}

fn title_from_href(archive: &mut ZipArchive<BufReader<File>>, href: &str) -> Option<String> {
    let content = read_zip_text(archive, href).ok()?;
    let re = Regex::new(r"(?is)<title[^>]*>([^<]+)</title>").ok()?;
    re.captures(&content)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().trim().to_string())
        .filter(|s| !s.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_fixtures::{write_sample_epub, write_sample_epub_covered, SampleCover};

    #[test]
    fn parse_sample_epub_metadata_and_chapters() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub(tmp.path(), "sample.epub");
        let info = parse_epub(&epub).expect("parse epub");

        assert_eq!(info.title, "Sample Book");
        assert_eq!(info.author, "Test Author");
        assert_eq!(info.language.as_deref(), Some("en"));
        assert_eq!(info.chapters.len(), 2);
        assert_eq!(info.chapters[0].key, "001");
        assert_eq!(info.chapters[0].title, "Introduction");
        assert_eq!(info.chapters[0].href, "OEBPS/chapter1.xhtml");
        assert_eq!(info.chapters[1].key, "002");
        assert_eq!(info.chapters[1].title, "The Market");
        assert!(info.cover.is_none());
    }

    #[test]
    fn extracts_epub3_property_cover() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_covered(tmp.path(), "epub3.epub", SampleCover::Epub3);
        let info = parse_epub(&epub).expect("parse epub");
        let cover = info.cover.expect("epub3 cover");
        assert_eq!(cover.extension, "png");
        assert_eq!(cover.bytes, crate::test_fixtures::SAMPLE_COVER_PNG);
    }

    #[test]
    fn extracts_epub2_meta_cover() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_covered(tmp.path(), "epub2.epub", SampleCover::Epub2);
        let info = parse_epub(&epub).expect("parse epub");
        assert!(info.cover.is_some());
    }

    #[test]
    fn falls_back_to_first_manifest_image() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_covered(tmp.path(), "bare.epub", SampleCover::BareImage);
        let info = parse_epub(&epub).expect("parse epub");
        assert!(info.cover.is_some());
    }

    #[test]
    fn parse_manifest_attributes_in_either_order() {
        // bdbbfcd: item attributes are unordered; href-before-id used to drop chapters.
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub(tmp.path(), "mixed-attrs.epub");
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters.len(), 2);
        assert_eq!(info.chapters[0].href, "OEBPS/chapter1.xhtml");
        assert_eq!(info.chapters[1].href, "OEBPS/chapter2.xhtml");
    }

    #[test]
    fn reject_non_epub_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("not.epub");
        std::fs::write(&path, b"not a zip").unwrap();
        assert!(parse_epub(&path).is_err());
    }
}
