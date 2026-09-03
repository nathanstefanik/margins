use margins_core::epub_meta;
use margins_core::Library;
use std::fs::{self, File};
use std::io::BufReader;
use std::path::{Path, PathBuf};
use zip::ZipArchive;

fn fixture_epubs() -> Vec<PathBuf> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    let mut paths: Vec<PathBuf> = fs::read_dir(&dir)
        .unwrap_or_else(|e| panic!("fixtures/ directory: {e}"))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "epub"))
        .collect();
    paths.sort();
    assert!(
        !paths.is_empty(),
        "put at least one .epub in fixtures/ (any book; used as a real-archive example)"
    );
    paths
}

#[test]
fn import_fixture_epubs_metadata_and_first_spine_resource() {
    for epub in fixture_epubs() {
        let parsed = epub_meta::parse_epub(&epub).unwrap_or_else(|e| {
            panic!("parse {}: {e}", epub.display());
        });
        assert!(!parsed.title.is_empty(), "{}: empty title", epub.display());
        assert!(
            !parsed.author.is_empty(),
            "{}: empty author",
            epub.display()
        );
        assert!(
            !parsed.chapters.is_empty(),
            "{}: no chapters",
            epub.display()
        );

        let tmp = tempfile::tempdir().unwrap();
        let library = Library::open(tmp.path().join("library")).unwrap();
        let meta = library
            .import_epub_with_progress(epub.clone(), |_, _| {})
            .unwrap_or_else(|e| panic!("import {}: {e}", epub.display()));

        assert_eq!(meta.title, parsed.title);
        assert_eq!(meta.author, parsed.author);
        assert_eq!(meta.chapters.len(), parsed.chapters.len());

        assert_eq!(
            meta.chapters_version,
            margins_core::library::CHAPTERS_VERSION
        );

        let source = library.book_dir(&meta.id).join("source.epub");
        let mut archive = ZipArchive::new(BufReader::new(File::open(source).unwrap())).unwrap();
        for chapter in &meta.chapters {
            // A chapter's href addresses the spine item and nothing else:
            // the TOC anchor lives in `fragment`, because both frontends
            // match relocation events against the bare path.
            assert!(
                !chapter.href.contains('#'),
                "{}: chapter {} href carries a fragment: {}",
                epub.display(),
                chapter.key,
                chapter.href
            );
            archive.by_name(&chapter.href).unwrap_or_else(|e| {
                panic!(
                    "{}: spine item {} missing from archive: {e}",
                    epub.display(),
                    chapter.href
                )
            });
        }
    }
}
