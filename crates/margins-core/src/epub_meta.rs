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

fn parse_manifest(opf: &str) -> Result<std::collections::HashMap<String, String>, EpubError> {
    let mut map = std::collections::HashMap::new();

    let mut reader = Reader::from_str(opf);
    reader.config_mut().trim_text(true);
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) | Ok(Event::Empty(element))
                if element.local_name().as_ref() == b"item" =>
            {
                let mut id = None;
                let mut href = None;

                for attribute in element.attributes() {
                    let attribute = attribute.map_err(|err| EpubError::Xml(err.to_string()))?;
                    let value = attribute
                        .decode_and_unescape_value(reader.decoder())
                        .map_err(|err| EpubError::Xml(err.to_string()))?
                        .into_owned();

                    match attribute.key.local_name().as_ref() {
                        b"id" => id = Some(value),
                        b"href" => href = Some(value),
                        _ => {}
                    }
                }

                if let (Some(id), Some(href)) = (id, href) {
                    map.insert(id, href);
                }
            }
            Ok(Event::Eof) => break,
            Err(err) => return Err(EpubError::Xml(err.to_string())),
            _ => {}
        }
    }

    Ok(map)
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
    use crate::test_fixtures::write_sample_epub;

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
