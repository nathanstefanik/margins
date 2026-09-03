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
    let toc = toc_by_path(&parse_toc(&mut archive, &opf, &opf_dir));

    // Titles resolve in two passes: collect every candidate first, then
    // pick, because the `<title>` rung needs to know which titles the whole
    // book shares before it can tell a chapter name from boilerplate.
    let mut candidates = Vec::new();
    for (index, idref) in spine.iter().enumerate() {
        let Some(href) = manifest.get(idref) else {
            continue;
        };
        if !is_probably_content(href) {
            continue;
        }
        let full_href = join_href(&opf_dir, href);
        let document = read_zip_text(&mut archive, &full_href).ok();
        let entry = toc.get(&normalize_path(&full_href));
        candidates.push(ChapterCandidate {
            index,
            href: full_href,
            fragment: entry.and_then(|entry| entry.fragment.clone()),
            toc_title: entry.map(|entry| entry.title.clone()),
            heading: document.as_deref().and_then(heading_from_document),
            document_title: document.as_deref().and_then(title_from_document),
        });
    }

    let chapters = resolve_chapter_titles(candidates, &metadata.title);

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

/// Every title source found for one spine item, before the chain picks
/// between them.
struct ChapterCandidate {
    index: usize,
    href: String,
    fragment: Option<String>,
    toc_title: Option<String>,
    heading: Option<String>,
    document_title: Option<String>,
}

/// A title used verbatim by this many chapters is a book-wide template
/// (Gutenberg's Ebookmaker stamps one `<title>` into every file), not a
/// chapter name.
const SHARED_TITLE_LIMIT: usize = 3;

/// Applies the title chain — TOC label, first heading, `<title>`, then a
/// positional fallback — with the shared-title pass that disqualifies
/// boilerplate. TOC labels are trusted as-is; they are per-entry by
/// construction.
fn resolve_chapter_titles(candidates: Vec<ChapterCandidate>, book_title: &str) -> Vec<ChapterMeta> {
    let shared_headings = shared_values(candidates.iter().filter_map(|c| c.heading.as_deref()));
    let shared_titles = shared_values(
        candidates
            .iter()
            .filter_map(|c| c.document_title.as_deref()),
    );

    candidates
        .into_iter()
        .map(|candidate| {
            let heading = candidate
                .heading
                .filter(|heading| !shared_headings.contains(heading.as_str()));
            let document_title = candidate.document_title.filter(|title| {
                !shared_titles.contains(title.as_str()) && !is_boilerplate_title(title, book_title)
            });
            let title = candidate
                .toc_title
                .or(heading)
                .or(document_title)
                .unwrap_or_else(|| format!("Chapter {}", candidate.index + 1));
            ChapterMeta {
                key: format!("{:03}", candidate.index + 1),
                index: candidate.index,
                title,
                href: candidate.href,
                fragment: candidate.fragment,
            }
        })
        .collect()
}

fn shared_values<'a>(values: impl Iterator<Item = &'a str>) -> std::collections::HashSet<String> {
    let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
    for value in values {
        *counts.entry(value).or_default() += 1;
    }
    counts
        .into_iter()
        .filter(|(_, count)| *count >= SHARED_TITLE_LIMIT)
        .map(|(value, _)| value.to_string())
        .collect()
}

/// The book's own name and Gutenberg's wrapper line are never a chapter
/// title, even in a book short enough to dodge the shared-title count.
fn is_boilerplate_title(title: &str, book_title: &str) -> bool {
    let title = title.trim();
    title.eq_ignore_ascii_case(book_title.trim())
        || title
            .to_lowercase()
            .starts_with("the project gutenberg ebook")
}

fn title_from_document(document: &str) -> Option<String> {
    let re = Regex::new(r"(?is)<title[^>]*>(.*?)</title\s*>").ok()?;
    re.captures(document)
        .and_then(|c| c.get(1))
        .and_then(|m| clean_text(m.as_str()))
}

/// The chapter's own first `<h1>`–`<h3>`: where the real name lives in
/// books whose `<title>` is a template. Absurdly long matches are rejected
/// — that is a heading wrapping the whole page, not a name.
fn heading_from_document(document: &str) -> Option<String> {
    let re = Regex::new(r"(?is)<h[123][^>]*>(.*?)</h[123]\s*>").ok()?;
    re.captures(document)
        .and_then(|c| c.get(1))
        .and_then(|m| clean_text(m.as_str()))
        .filter(|heading| heading.chars().count() <= 200)
}

/// Flattens a snippet of markup to display text: tags out, entities
/// decoded, whitespace collapsed. `None` when nothing is left.
fn clean_text(markup: &str) -> Option<String> {
    let re = Regex::new(r"(?s)<[^>]*>").ok()?;
    let text = decode_entities(&re.replace_all(markup, " "));
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    Some(collapsed).filter(|s| !s.is_empty())
}

/// Decodes the handful of entities that show up in titles and headings,
/// plus numeric references. Unknown entities are left alone.
fn decode_entities(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find('&') {
        out.push_str(&rest[..start]);
        rest = &rest[start..];
        let Some(end) = rest[..rest.len().min(12)].find(';') else {
            out.push('&');
            rest = &rest[1..];
            continue;
        };
        let entity = &rest[1..end];
        let decoded = match entity.to_ascii_lowercase().as_str() {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" | "#39" => Some('\''),
            "nbsp" => Some(' '),
            "mdash" => Some('\u{2014}'),
            "ndash" => Some('\u{2013}'),
            "hellip" => Some('\u{2026}'),
            "rsquo" => Some('\u{2019}'),
            "lsquo" => Some('\u{2018}'),
            "ldquo" => Some('\u{201C}'),
            "rdquo" => Some('\u{201D}'),
            _ => numeric_entity(entity),
        };
        match decoded {
            Some(character) => {
                out.push(character);
                rest = &rest[end + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

fn numeric_entity(entity: &str) -> Option<char> {
    let digits = entity.strip_prefix('#')?;
    let code = match digits
        .strip_prefix('x')
        .or_else(|| digits.strip_prefix('X'))
    {
        Some(hex) => u32::from_str_radix(hex, 16).ok()?,
        None => digits.parse().ok()?,
    };
    char::from_u32(code)
}

/// One TOC entry, flattened out of the nav document or NCX in reading
/// order and resolved against the book root.
#[derive(Debug, Clone, PartialEq, Eq)]
struct TocEntry {
    title: String,
    /// In-zip path of the target file, normalized for comparison.
    path: String,
    fragment: Option<String>,
}

/// The book's table of contents, preferring the EPUB3 nav document and
/// falling back to the NCX. TOC parsing is best-effort by design: a
/// malformed or missing TOC yields an empty list rather than failing the
/// import, and the title chain simply falls through to the next rung.
fn parse_toc(archive: &mut ZipArchive<BufReader<File>>, opf: &str, opf_dir: &str) -> Vec<TocEntry> {
    let Ok(items) = parse_manifest_items(opf) else {
        return Vec::new();
    };

    let nav = items.iter().find(|item| {
        item.properties
            .as_deref()
            .is_some_and(|properties| properties.split_whitespace().any(|p| p == "nav"))
    });
    if let Some(item) = nav {
        let path = join_href(opf_dir, &item.href);
        if let Ok(document) = read_zip_text(archive, &path) {
            let entries = parse_nav_document(&document, &parent_dir(&path));
            if !entries.is_empty() {
                return entries;
            }
        }
    }

    // NCX: the declared media type first, then the id named by
    // `<spine toc="...">`, then any `.ncx` in the manifest.
    let toc_id = spine_toc_id(opf);
    let ncx = items
        .iter()
        .find(|item| item.media_type.as_deref() == Some("application/x-dtbncx+xml"))
        .or_else(|| {
            toc_id
                .as_deref()
                .and_then(|id| items.iter().find(|item| item.id == id))
        })
        .or_else(|| {
            items
                .iter()
                .find(|item| item.href.to_lowercase().ends_with(".ncx"))
        });
    if let Some(item) = ncx {
        let path = join_href(opf_dir, &item.href);
        if let Ok(document) = read_zip_text(archive, &path) {
            return parse_ncx(&document, &parent_dir(&path));
        }
    }

    Vec::new()
}

/// Indexes the TOC by target path, first entry in reading order winning:
/// a file split into several TOC entries starts at the first of them.
fn toc_by_path(entries: &[TocEntry]) -> std::collections::HashMap<String, TocEntry> {
    let mut map = std::collections::HashMap::new();
    for entry in entries {
        map.entry(entry.path.clone())
            .or_insert_with(|| entry.clone());
    }
    map
}

fn spine_toc_id(opf: &str) -> Option<String> {
    let re = Regex::new(r#"<spine\s+[^>]*?toc="([^"]+)""#).ok()?;
    re.captures(opf)
        .and_then(|c| c.get(1))
        .map(|m| m.as_str().to_string())
}

/// EPUB3 nav document: the `<nav>` marked as the TOC (`epub:type="toc"`,
/// else `role="doc-toc"`, else the first one with links), flattened to its
/// anchors in document order.
fn parse_nav_document(xml: &str, base_dir: &str) -> Vec<TocEntry> {
    struct NavSection {
        epub_type: Option<String>,
        role: Option<String>,
        anchors: Vec<(String, String)>,
    }

    let mut sections: Vec<NavSection> = Vec::new();
    // Indices of the `<nav>` elements currently open; anchors belong to the
    // innermost one.
    let mut open: Vec<usize> = Vec::new();
    let mut anchor: Option<(String, String)> = None;

    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    loop {
        match reader.read_event() {
            Ok(Event::Start(element)) => match element.local_name().as_ref() {
                b"nav" => {
                    open.push(sections.len());
                    sections.push(NavSection {
                        epub_type: attribute_value(&element, b"type"),
                        role: attribute_value(&element, b"role"),
                        anchors: Vec::new(),
                    });
                }
                b"a" if !open.is_empty() => {
                    anchor = attribute_value(&element, b"href").map(|href| (href, String::new()));
                }
                _ => {}
            },
            Ok(Event::Text(text)) => {
                if let Some((_, label)) = anchor.as_mut() {
                    if let Ok(decoded) = text.unescape() {
                        label.push_str(&decoded);
                    }
                }
            }
            Ok(Event::End(element)) => match element.local_name().as_ref() {
                b"nav" => {
                    open.pop();
                    anchor = None;
                }
                b"a" => {
                    if let (Some(anchor), Some(index)) = (anchor.take(), open.last()) {
                        sections[*index].anchors.push(anchor);
                    }
                }
                _ => {}
            },
            Ok(Event::Eof) => break,
            Err(_) => return Vec::new(),
            _ => {}
        }
    }

    let chosen = sections
        .iter()
        .find(|section| {
            section
                .epub_type
                .as_deref()
                .is_some_and(|value| value.split_whitespace().any(|part| part == "toc"))
        })
        .or_else(|| {
            sections
                .iter()
                .find(|section| section.role.as_deref() == Some("doc-toc"))
        })
        .or_else(|| sections.iter().find(|section| !section.anchors.is_empty()));

    let Some(chosen) = chosen else {
        return Vec::new();
    };
    chosen
        .anchors
        .iter()
        .filter_map(|(href, label)| toc_entry(base_dir, href, label))
        .collect()
}

/// NCX `navMap`: nested `navPoint`s flattened depth-first. Each point is
/// emitted at the slot it opened, so a parent still precedes its children
/// even though its `</navPoint>` closes last.
fn parse_ncx(xml: &str, base_dir: &str) -> Vec<TocEntry> {
    let mut entries: Vec<TocEntry> = Vec::new();
    let mut stack: Vec<Pending> = Vec::new();
    let mut in_label = false;
    let mut in_text = false;

    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(false);
    loop {
        match reader.read_event() {
            // Only `Start` opens a navPoint: a self-closing one carries no
            // label or target, and pushing it would leave a frame that no
            // `</navPoint>` ever pops.
            Ok(Event::Start(element)) => match element.local_name().as_ref() {
                b"navPoint" => stack.push(Pending {
                    slot: entries.len(),
                    label: String::new(),
                    src: None,
                }),
                b"navLabel" => in_label = true,
                b"text" if in_label => in_text = true,
                b"content" => set_navpoint_src(&mut stack, &element),
                _ => {}
            },
            // `<content src="..."/>` is always empty in practice.
            Ok(Event::Empty(element)) => {
                if element.local_name().as_ref() == b"content" {
                    set_navpoint_src(&mut stack, &element);
                }
            }
            Ok(Event::Text(text)) => {
                if in_text {
                    if let (Ok(decoded), Some(pending)) = (text.unescape(), stack.last_mut()) {
                        pending.label.push_str(&decoded);
                    }
                }
            }
            Ok(Event::End(element)) => match element.local_name().as_ref() {
                b"navPoint" => {
                    if let Some(pending) = stack.pop() {
                        if let Some(entry) = pending
                            .src
                            .as_deref()
                            .and_then(|src| toc_entry(base_dir, src, &pending.label))
                        {
                            entries.insert(pending.slot, entry);
                        }
                    }
                }
                b"navLabel" => in_label = false,
                b"text" => in_text = false,
                _ => {}
            },
            Ok(Event::Eof) => break,
            Err(_) => return Vec::new(),
            _ => {}
        }
    }

    entries
}

/// A navPoint being read: `slot` is where it goes in reading order, held
/// open until `</navPoint>` so a parent still precedes the children that
/// close before it.
struct Pending {
    slot: usize,
    label: String,
    src: Option<String>,
}

/// Records a `<content src>` on the innermost open navPoint. The first one
/// wins: a malformed point with two targets starts where it says first.
fn set_navpoint_src(stack: &mut [Pending], element: &quick_xml::events::BytesStart) {
    if let (Some(src), Some(pending)) = (attribute_value(element, b"src"), stack.last_mut()) {
        if pending.src.is_none() {
            pending.src = Some(src);
        }
    }
}

/// Builds an entry from a raw TOC target and label, dropping ones with no
/// usable label or path.
fn toc_entry(base_dir: &str, src: &str, label: &str) -> Option<TocEntry> {
    let title = clean_text(label)?;
    let (path, fragment) = match src.split_once('#') {
        Some((path, fragment)) => (path, Some(fragment)),
        None => (src, None),
    };
    let path = normalize_path(&resolve_relative(base_dir, &percent_decode(path)));
    if path.is_empty() {
        return None;
    }
    Some(TocEntry {
        title,
        path,
        fragment: fragment.map(percent_decode).filter(|f| !f.is_empty()),
    })
}

fn attribute_value(element: &quick_xml::events::BytesStart, name: &[u8]) -> Option<String> {
    element
        .attributes()
        .flatten()
        .find(|attribute| attribute.key.local_name().as_ref() == name)
        .and_then(|attribute| attribute.unescape_value().ok().map(|v| v.into_owned()))
}

fn parent_dir(path: &str) -> String {
    match path.rfind('/') {
        Some(index) => path[..index].to_string(),
        None => String::new(),
    }
}

/// Resolves a TOC target against the directory of the document that
/// declared it (nav/NCX srcs are relative to that file, not the OPF),
/// collapsing `.` and `..`.
fn resolve_relative(base_dir: &str, href: &str) -> String {
    let mut stack: Vec<&str> = if href.starts_with('/') {
        Vec::new()
    } else {
        base_dir
            .split('/')
            .filter(|part| !part.is_empty())
            .collect()
    };
    for part in href.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                stack.pop();
            }
            part => stack.push(part),
        }
    }
    stack.join("/")
}

/// Comparison form of an in-zip path: percent-decoded, with any leading
/// `./` or `/` removed, so a TOC target and a manifest href for the same
/// file agree however each was written.
fn normalize_path(path: &str) -> String {
    resolve_relative("", &percent_decode(path))
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[index + 1..index + 3])
                .ok()
                .and_then(|hex| u8::from_str_radix(hex, 16).ok());
            if let Some(byte) = hex {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_fixtures::{
        write_epub_with_titles, write_sample_epub, write_sample_epub_covered,
        write_sample_epub_toc, SampleCover, SampleToc,
    };

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
    fn ncx_labels_and_fragments_beat_document_titles() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_toc(tmp.path(), "ncx.epub", SampleToc::Ncx);
        let info = parse_epub(&epub).expect("parse epub");

        // The nested navPoint targets the same file, so the first entry in
        // reading order is the one that names the chapter.
        assert_eq!(info.chapters[0].title, "Opening Remarks");
        assert_eq!(info.chapters[0].fragment.as_deref(), Some("start"));
        assert_eq!(info.chapters[0].href, "OEBPS/chapter1.xhtml");
        assert_eq!(info.chapters[1].title, "Market Day");
        assert_eq!(info.chapters[1].fragment, None);
    }

    #[test]
    fn epub3_nav_document_supplies_titles_and_fragments() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_toc(tmp.path(), "nav.epub", SampleToc::Nav);
        let info = parse_epub(&epub).expect("parse epub");

        // Inline markup inside the anchor is flattened, and the decoy
        // `landmarks` nav (which would have said "Start Reading") loses.
        assert_eq!(info.chapters[0].title, "Opening Remarks");
        assert_eq!(info.chapters[0].fragment.as_deref(), Some("start"));
        assert_eq!(info.chapters[1].title, "Market Day");
        assert_eq!(info.chapters[1].fragment, None);
    }

    #[test]
    fn toc_entries_for_non_spine_files_are_ignored() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub_toc(tmp.path(), "ncx.epub", SampleToc::Ncx);
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters.len(), 2);
        assert!(!info.chapters.iter().any(|c| c.title == "Colophon"));
    }

    #[test]
    fn missing_toc_leaves_chapters_without_fragments() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_sample_epub(tmp.path(), "plain.epub");
        let info = parse_epub(&epub).expect("parse epub");
        assert!(info.chapters.iter().all(|c| c.fragment.is_none()));
        assert_eq!(info.chapters[0].title, "Introduction");
    }

    #[test]
    fn shared_document_titles_fall_back_to_headings() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_epub_with_titles(
            tmp.path(),
            "shared.epub",
            "Sample Book",
            &[
                ("A Template", "First Movement"),
                ("A Template", "Second Movement"),
                ("A Template", "Third Movement"),
            ],
        );
        let info = parse_epub(&epub).expect("parse epub");
        let titles: Vec<&str> = info.chapters.iter().map(|c| c.title.as_str()).collect();
        assert_eq!(
            titles,
            ["First Movement", "Second Movement", "Third Movement"]
        );
    }

    #[test]
    fn two_chapters_keep_a_shared_document_title() {
        // Below the shared-title limit a repeated `<title>` is far more
        // likely to be a real (if unimaginative) name than a template.
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_epub_with_titles(
            tmp.path(),
            "pair.epub",
            "Sample Book",
            &[("Shared Name", ""), ("Shared Name", "")],
        );
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters[0].title, "Shared Name");
        assert_eq!(info.chapters[1].title, "Shared Name");
    }

    #[test]
    fn book_title_and_gutenberg_boilerplate_are_never_chapter_titles() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_epub_with_titles(
            tmp.path(),
            "Sample Book",
            "Sample Book",
            &[
                ("Sample Book", "The Opening"),
                ("The Project Gutenberg eBook of Sample Book", "The Closing"),
            ],
        );
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters[0].title, "The Opening");
        assert_eq!(info.chapters[1].title, "The Closing");
    }

    #[test]
    fn headings_are_flattened_and_entities_decoded() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_epub_with_titles(
            tmp.path(),
            "Sample Book",
            "Sample Book",
            &[("Sample Book", "Fathers <em>&amp;</em>\n  Sons")],
        );
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters[0].title, "Fathers & Sons");
    }

    #[test]
    fn chapters_with_no_title_source_fall_back_to_position() {
        let tmp = tempfile::tempdir().unwrap();
        let epub = write_epub_with_titles(tmp.path(), "bare.epub", "Sample Book", &[("", "")]);
        let info = parse_epub(&epub).expect("parse epub");
        assert_eq!(info.chapters[0].title, "Chapter 1");
    }

    /// Gutenberg's Ebookmaker stamps the book title into every file's
    /// `<title>`, so this fixture only reads correctly when the NCX drives
    /// the chapter names.
    #[test]
    fn karamazov_fixture_titles_come_from_the_ncx() {
        let epub = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/dostoyevsky_the_karamazov_brothers.epub");
        let info = parse_epub(&epub).expect("parse fixture");

        assert!(info.chapters.len() > 50);
        assert!(
            !info
                .chapters
                .iter()
                .any(|chapter| chapter.title.starts_with("The Project Gutenberg eBook")),
            "boilerplate <title> leaked into chapter names"
        );
        let first = &info.chapters[0].title;
        assert!(
            info.chapters.iter().any(|chapter| &chapter.title != first),
            "every chapter got the same title"
        );

        let chapter = info
            .chapters
            .iter()
            .find(|chapter| chapter.title == "Chapter II. He Gets Rid Of His Eldest Son")
            .expect("NCX-labelled chapter");
        assert_eq!(chapter.fragment.as_deref(), Some("pgepubid00008"));
        assert!(chapter.href.ends_with("28054-h-3.htm.html"));
        assert!(!chapter.href.contains('#'));
    }

    #[test]
    fn reject_non_epub_file() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("not.epub");
        std::fs::write(&path, b"not a zip").unwrap();
        assert!(parse_epub(&path).is_err());
    }
}
