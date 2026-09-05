//! Parse/serialize the marks section of a chapter note file, and generate
//! mark ids. See `docs/storage.md` for the format; the properties that
//! drive every decision here:
//!
//! - Everything above the `<!-- margins:marks -->` sentinel is the
//!   long-form body; the section below it is an append log of blocks.
//! - Untouched blocks are re-emitted **byte-identically** — editing or
//!   deleting one mark never rewrites unrelated ones.
//! - Unparsable content inside the section is preserved verbatim rather
//!   than dropped. Losslessness beats tidiness.

use crate::models::Mark;
use chrono::{DateTime, SecondsFormat, Utc};

/// Starts the marks section. The first occurrence after the frontmatter
/// wins; a later one inside a mark body is just text.
pub const SENTINEL: &str = "<!-- margins:marks -->";

/// A block of the marks section: a parsed mark keeping its exact source
/// bytes, or unparsable lines preserved verbatim.
#[derive(Debug, Clone, PartialEq)]
pub enum MarkItem {
    Mark { mark: Mark, raw: String },
    Raw(String),
}

/// Generates a fresh mark id: 10 lowercase Crockford-base32 characters,
/// time-ordered (millisecond clock since a custom epoch) with 10 bits of
/// per-millisecond randomness. Callers retry on the (unlikely) collision
/// with an existing id, so uniqueness holds without coordination.
pub fn new_mark_id() -> String {
    // 2020-01-01T00:00:00Z; 40 bits of milliseconds reach ~2054.
    const EPOCH_MS: i64 = 1_577_836_800_000;
    const ALPHABET: &[u8] = b"0123456789abcdefghjkmnpqrstvwxyz";

    let now_ms = Utc::now().timestamp_millis().max(EPOCH_MS) - EPOCH_MS;
    let mut value = (now_ms << 10) as u64 | (rand_u10() as u64);
    let mut id = [b'0'; 10];
    for ch in id.iter_mut().rev() {
        *ch = ALPHABET[(value & 31) as usize];
        value >>= 5;
    }
    String::from_utf8(id.to_vec()).expect("crockford alphabet is ascii")
}

/// Small non-crypto random source for id suffixes: nanos mixed by a
/// splitmix-style step. Adequate — collisions are retried by callers.
fn rand_u10() -> u32 {
    let nanos = Utc::now().timestamp_subsec_nanos() as u64;
    let mut z = (nanos << 13) ^ std::process::id() as u64;
    z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_8ce4_e809);
    z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
    ((z ^ (z >> 31)) & 0x3ff) as u32
}

/// Splits post-frontmatter content into the long-form body and the marks
/// section lines (present when the sentinel appears). The sentinel must
/// head its own line; the first occurrence wins. The body loses any blank
/// lines immediately before the sentinel — those are the canonical
/// separator, re-added on save.
pub fn split_body(content: &str) -> (String, Option<String>) {
    let mut body_lines = Vec::new();
    for (idx, line) in content.lines().enumerate() {
        if line.trim() == SENTINEL {
            let rest = content
                .lines()
                .skip(idx + 1)
                .skip_while(|l| l.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            while body_lines.last().is_some_and(|l: &&str| l.trim().is_empty()) {
                body_lines.pop();
            }
            return (body_lines.join("\n"), Some(rest));
        }
        body_lines.push(line);
    }
    (content.to_string(), None)
}

/// Parses a marks section into blocks. Stray text before the first mark
/// comment and hand-mangled mark comments both come back as `Raw` blocks.
/// The string may optionally begin with the sentinel line itself (as a
/// whole file body would); it is skipped.
pub fn parse_section(lines: &str) -> Vec<MarkItem> {
    let mut items: Vec<MarkItem> = Vec::new();
    let mut header: Option<String> = None;
    let mut content: Vec<&str> = Vec::new();
    let mut raw: Vec<&str> = Vec::new();
    let mut leading_sentinel = true;

    let mut flush = |header: &mut Option<String>, content: &mut Vec<&str>, raw: &mut Vec<&str>| {
        if let Some(comment) = header.take() {
            let raw_text = join_block(&comment, content);
            items.push(match parse_comment(&comment) {
                Some(partial) => match split_quote_body(content) {
                    Some((quote, body)) => MarkItem::Mark {
                        mark: Mark {
                            id: partial.id,
                            cfi: partial.cfi,
                            at: partial.at,
                            percent: partial.percent,
                            quote,
                            body,
                        },
                        raw: raw_text,
                    },
                    None => MarkItem::Raw(raw_text),
                },
                None => MarkItem::Raw(raw_text),
            });
            content.clear();
        } else if !raw.is_empty() {
            let text = raw.join("\n");
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                items.push(MarkItem::Raw(trimmed.to_string()));
            }
            raw.clear();
        }
    };

    for line in lines.lines() {
        if leading_sentinel {
            leading_sentinel = false;
            if line.trim() == SENTINEL {
                continue;
            }
        }
        if let Some(comment) = mark_comment_line(line) {
            flush(&mut header, &mut content, &mut raw);
            header = Some(comment.to_string());
        } else if header.is_some() {
            content.push(line);
        } else {
            raw.push(line);
        }
    }
    flush(&mut header, &mut content, &mut raw);
    items
}

/// Re-renders blocks canonically: one blank line between blocks, section
/// terminated by a newline. Untouched `Mark` blocks reuse their source
/// bytes, so unrelated marks keep their exact formatting.
pub fn serialize_items(items: &[MarkItem]) -> String {
    let blocks: Vec<String> = items
        .iter()
        .map(|item| match item {
            MarkItem::Mark { raw, .. } => raw.clone(),
            MarkItem::Raw(text) => text.clone(),
        })
        .collect();
    format!("{SENTINEL}\n\n{}\n", blocks.join("\n\n"))
}

/// Canonical text of a single mark block (comment + quote + body).
pub fn canonical_block(mark: &Mark) -> String {
    let mut block = format!("{} -->\n", mark_comment_prefix(mark));
    if !mark.quote.is_empty() {
        for line in mark.quote.lines() {
            block.push_str("> ");
            block.push_str(line);
            block.push('\n');
        }
    }
    if !mark.body.is_empty() {
        block.push('\n');
        block.push_str(&mark.body);
        block.push('\n');
    }
    block.trim_end().to_string()
}

/// Appends a canonical block for `mark` to `items`, keeping everything
/// else byte-identical.
pub fn append_item(items: &mut Vec<MarkItem>, mark: Mark) {
    items.push(MarkItem::Mark {
        raw: canonical_block(&mark),
        mark,
    });
}

/// Replaces the block with `mark.id`, re-rendering it canonically; every
/// other block keeps its source bytes. Returns false when the id is unknown.
pub fn update_item(items: &mut [MarkItem], mark: Mark) -> bool {
    for item in items.iter_mut() {
        if let MarkItem::Mark { mark: existing, .. } = item {
            if existing.id == mark.id {
                *item = MarkItem::Mark {
                    raw: canonical_block(&mark),
                    mark,
                };
                return true;
            }
        }
    }
    false
}

/// Removes the block with `id`; every other block keeps its source bytes.
/// Returns false when the id is unknown. Takes `Vec` because removal
/// shortens the section — a slice cannot truncate.
#[allow(clippy::ptr_arg)]
pub fn delete_item(items: &mut Vec<MarkItem>, id: &str) -> bool {
    let before = items.len();
    items.retain(|item| match item {
        MarkItem::Mark { mark, .. } => mark.id != id,
        MarkItem::Raw(_) => true,
    });
    items.len() != before
}

/// The `Mark` records of a section, disk order preserved (callers sort
/// when they need reading order).
pub fn marks(items: &[MarkItem]) -> Vec<Mark> {
    items
        .iter()
        .filter_map(|item| match item {
            MarkItem::Mark { mark, .. } => Some(mark.clone()),
            MarkItem::Raw(_) => None,
        })
        .collect()
}

/// Reading order for display: percent ascending, then CFI, then id;
/// marks without a percent go last.
pub fn sort_reading_order(items: &mut [Mark]) {
    items.sort_by(|a, b| {
        a.percent
            .unwrap_or(f64::MAX)
            .partial_cmp(&b.percent.unwrap_or(f64::MAX))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.cfi.cmp(&b.cfi))
            .then_with(|| a.id.cmp(&b.id))
    });
}

// --- internals -------------------------------------------------------------

fn join_block(comment: &str, content: &[&str]) -> String {
    let mut text = comment.to_string();
    for line in content {
        text.push('\n');
        text.push_str(line);
    }
    text.trim_end().to_string()
}

/// Returns the comment text when `line` starts a mark block —
/// `<!-- margins:mark ... -->`. The sentinel (`margins:marks`) does not
/// match: the character after `mark` must be whitespace.
fn mark_comment_line(line: &str) -> Option<&str> {
    let trimmed = line.trim();
    let rest = trimmed.strip_prefix("<!--")?.trim_start();
    let rest = rest.strip_prefix("margins:mark")?;
    if !rest.starts_with(|c: char| c.is_whitespace()) {
        return None;
    }
    trimmed.strip_suffix("-->")?;
    Some(trimmed)
}

struct PartialMark {
    id: String,
    cfi: Option<String>,
    at: DateTime<Utc>,
    percent: Option<f64>,
}

/// Parses `<!-- margins:mark id=... cfi="..." at=... percent=... -->`.
/// Missing/unparsable `id` or `at` fails the whole block (it is kept as
/// `Raw`); a malformed `cfi`/`percent` degrades gracefully.
fn parse_comment(comment: &str) -> Option<PartialMark> {
    let inner = comment
        .trim()
        .strip_prefix("<!--")?
        .strip_suffix("-->")?
        .trim();
    let attrs = inner.strip_prefix("margins:mark")?.trim();

    let mut id = None;
    let mut cfi = None;
    let mut at = None;
    let mut percent = None;

    for (key, value) in parse_attrs(attrs) {
        match key.as_str() {
            "id" => id = Some(value),
            "cfi" => {
                cfi = Some(value);
            }
            "at" => at = DateTime::parse_from_rfc3339(&value).ok().map(|t| t.with_timezone(&Utc)),
            "percent" => percent = value.parse::<f64>().ok(),
            _ => {}
        }
    }

    Some(PartialMark {
        id: id?,
        cfi: cfi.filter(|c| !c.is_empty()),
        at: at?,
        percent,
    })
}

/// Whitespace-separated `key=value` tokens; values may be double-quoted.
fn parse_attrs(attrs: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut chars = attrs.chars().peekable();
    while let Some(&ch) = chars.peek() {
        if ch.is_whitespace() {
            chars.next();
            continue;
        }
        let mut key = String::new();
        while let Some(&c) = chars.peek() {
            if c == '=' || c.is_whitespace() {
                break;
            }
            key.push(c);
            chars.next();
        }
        if chars.peek() != Some(&'=') {
            // Bare token — skip to the next whitespace boundary.
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() {
                    break;
                }
                chars.next();
            }
            continue;
        }
        chars.next(); // '='
        let mut value = String::new();
        if chars.peek() == Some(&'"') {
            chars.next();
            for c in chars.by_ref() {
                if c == '"' {
                    break;
                }
                value.push(c);
            }
        } else {
            while let Some(&c) = chars.peek() {
                if c.is_whitespace() {
                    break;
                }
                value.push(c);
                chars.next();
            }
        }
        pairs.push((key, value));
    }
    pairs
}

/// Splits block content into the leading `>`-blockquote (the quoted
/// selection) and the remaining body. A block with neither is invalid
/// (`None`) — a mark comment with nothing under it carries no information.
fn split_quote_body(content: &[&str]) -> Option<(String, String)> {
    let mut quote_lines: Vec<&str> = Vec::new();
    let mut rest = content;
    while let Some(line) = rest.first() {
        let quote = line.trim_start().strip_prefix('>');
        match quote {
            Some(q) => {
                quote_lines.push(q.strip_prefix(' ').unwrap_or(q));
                rest = &rest[1..];
            }
            None => break,
        }
    }
    // Skip blank lines between quote and body.
    while rest.first().is_some_and(|l| l.trim().is_empty()) {
        rest = &rest[1..];
    }
    let body = rest.join("\n").trim().to_string();
    let quote = quote_lines.join("\n");
    if quote.is_empty() && body.is_empty() {
        return None;
    }
    Some((quote, body))
}

fn mark_comment_prefix(mark: &Mark) -> String {
    let mut prefix = format!(
        "<!-- margins:mark id={} cfi=\"{}\" at={}",
        mark.id,
        mark.cfi.clone().unwrap_or_default(),
        mark.at.to_rfc3339_opts(SecondsFormat::Secs, true)
    );
    if let Some(percent) = mark.percent {
        prefix.push_str(&format!(" percent={percent:.1}"));
    }
    prefix
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mark(id: &str, percent: Option<f64>, quote: &str, body: &str) -> Mark {
        Mark {
            id: id.to_string(),
            cfi: Some("epubcfi(/6/14!/4/2)".into()),
            // Canonical `at` is second-precision (see mark_comment_prefix).
            at: DateTime::from_timestamp(Utc::now().timestamp(), 0)
                .unwrap()
                .with_timezone(&Utc),
            percent,
            quote: quote.into(),
            body: body.into(),
        }
    }

    #[test]
    fn canonical_block_round_trips_through_parser() {
        let m = mark("b01j8q3k2m", Some(38.2), "quoted selection", "The quick thought.");
        let block = canonical_block(&m);
        let items = parse_section(&format!("{SENTINEL}\n\n{block}\n"));
        let parsed = marks(&items);
        assert_eq!(parsed.len(), 1);
        assert_eq!(parsed[0].id, m.id);
        assert_eq!(parsed[0].quote, m.quote);
        assert_eq!(parsed[0].body, m.body);
        assert_eq!(parsed[0].percent, m.percent);
        assert_eq!(parsed[0].cfi, m.cfi);
        assert_eq!(parsed[0].at, m.at);
        // Canonical bytes are stable: serialize(parse(canonical)) == canonical.
        match &items[0] {
            MarkItem::Mark { raw, .. } => assert_eq!(*raw, block),
            _ => panic!("expected a mark block"),
        }
    }

    #[test]
    fn highlight_without_body_and_note_without_quote_both_round_trip() {
        let highlight = mark("b01j8q3k2m", None, "just a quote", "");
        let note = mark("b01j8q3k3n", None, "", "thought only");
        let text = format!(
            "{SENTINEL}\n\n{}\n\n{}\n",
            canonical_block(&highlight),
            canonical_block(&note)
        );
        let parsed = marks(&parse_section(&text));
        assert_eq!(parsed.len(), 2);
        assert_eq!(parsed[0].quote, "just a quote");
        assert_eq!(parsed[0].body, "");
        assert_eq!(parsed[1].quote, "");
        assert_eq!(parsed[1].body, "thought only");
    }

    #[test]
    fn unparsable_blocks_are_preserved_verbatim() {
        let section = format!(
            "{SENTINEL}\n\nsome stray text\n\n<!-- margins:mark id= no-at -->\n> broken\n\n{}\n",
            canonical_block(&mark("b01j8q3k4p", None, "q", "b"))
        );
        let items = parse_section(&section);
        assert_eq!(items.len(), 3);
        assert!(matches!(&items[0], MarkItem::Raw(t) if t == "some stray text"));
        assert!(matches!(&items[1], MarkItem::Raw(t) if t.contains("> broken")));
        assert!(matches!(&items[2], MarkItem::Mark { .. }));
        // Everything survives a re-serialization.
        let out = serialize_items(&items);
        let reparsed = parse_section(&out);
        assert_eq!(marks(&reparsed).len(), 1);
        assert_eq!(reparsed.len(), items.len());
    }

    #[test]
    fn sentinel_inside_mark_body_is_just_text() {
        let section = format!(
            "{SENTINEL}\n\n{}\n",
            canonical_block(&mark("b01j8q3k5q", None, "", "see <!-- margins:marks --> below"))
        );
        let parsed = marks(&parse_section(&section));
        assert_eq!(parsed.len(), 1);
        assert!(parsed[0].body.contains("<!-- margins:marks -->"));
    }

    #[test]
    fn untouched_blocks_keep_their_bytes_through_update_and_delete() {
        let a = mark("baaaaaaaaaa", None, "quote a", "body a");
        let b = mark("bbbbbbbbbbb", None, "quote b", "body b");
        let c = mark("ccccccccccc", None, "quote c", "body c");
        let mut items = Vec::new();
        append_item(&mut items, a.clone());
        append_item(&mut items, b.clone());
        append_item(&mut items, c.clone());

        // Update the middle one; a and c keep their bytes.
        let mut b2 = b.clone();
        b2.body = "edited body b".into();
        assert!(update_item(&mut items, b2));
        let raws: Vec<&String> = items
            .iter()
            .map(|i| match i {
                MarkItem::Mark { raw, .. } => raw,
                MarkItem::Raw(t) => t,
            })
            .collect();
        assert!(raws[0].contains("body a"));
        assert!(raws[1].contains("edited body b"));
        assert!(raws[2].contains("body c"));

        // Delete the first; c still keeps its bytes.
        assert!(delete_item(&mut items, &a.id));
        let raws: Vec<&String> = items
            .iter()
            .map(|i| match i {
                MarkItem::Mark { raw, .. } => raw,
                MarkItem::Raw(t) => t,
            })
            .collect();
        assert_eq!(raws.len(), 2);
        assert!(raws[1].contains("body c"));
        assert!(!delete_item(&mut items, "zzzzzzzzzzz"));
    }

    #[test]
    fn ids_are_time_ordered_and_wellformed() {
        let first = new_mark_id();
        std::thread::sleep(std::time::Duration::from_millis(3));
        let second = new_mark_id();
        assert_eq!(first.len(), 10);
        assert_eq!(second.len(), 10);
        assert!(first.chars().all(|c| "0123456789abcdefghjkmnpqrstvwxyz".contains(c)));
        assert!(first < second, "ids must sort by time: {first} !< {second}");
    }

    #[test]
    fn quoted_attribute_values_parse_with_spaces_and_quotes() {
        let section = format!(
            "{SENTINEL}\n\n<!-- margins:mark id=b01j8q3k6r cfi=\"epubcfi(/6/14!/4/2/10,/1:0,/1:42)\" at=2026-09-05T14:02:11Z percent=38.2 -->\n> q\n\nb\n"
        );
        let parsed = marks(&parse_section(&section));
        assert_eq!(parsed.len(), 1);
        assert_eq!(
            parsed[0].cfi.as_deref(),
            Some("epubcfi(/6/14!/4/2/10,/1:0,/1:42)")
        );
        assert_eq!(parsed[0].percent, Some(38.2));
    }

    #[test]
    fn split_body_finds_first_sentinel_only() {
        let content = "prose\n\n<!-- margins:marks -->\n\nmark stuff";
        let (body, section) = split_body(content);
        assert_eq!(body, "prose");
        assert_eq!(section.as_deref(), Some("mark stuff"));

        let (body, section) = split_body("just prose");
        assert_eq!(body, "just prose");
        assert!(section.is_none());
    }

    #[test]
    fn reading_order_puts_percentless_marks_last() {
        let mut list = vec![
            mark("bbbbbbbbbbb", None, "q", "b"),
            mark("ccccccccccc", Some(51.0), "q", "b"),
            mark("aaaaaaaaaaa", Some(38.0), "q", "b"),
        ];
        sort_reading_order(&mut list);
        let ids: Vec<&str> = list.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["aaaaaaaaaaa", "ccccccccccc", "bbbbbbbbbbb"]);
    }
}
