use margins_core::Library;
use std::fs::File;
use std::io::BufReader;
use std::path::{Path, PathBuf};
use zip::ZipArchive;

fn karamazov_epub() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures/dostoyevsky_the_karamazov_brothers.epub")
        .canonicalize()
        .expect("karamazov fixture")
}

#[test]
fn import_karamazov_metadata_and_first_spine_resource() {
    let tmp = tempfile::tempdir().unwrap();
    let library = Library::open(tmp.path().join("library")).unwrap();
    let meta = library
        .import_epub_with_progress(karamazov_epub(), |_, _| {})
        .unwrap();

    assert!(!meta.title.is_empty());
    assert!(!meta.author.is_empty());
    assert_eq!(meta.title, "The Brothers Karamazov");
    assert_eq!(meta.author, "Fyodor Dostoyevsky");
    assert_eq!(meta.chapters.len(), 100);

    let source = library.book_dir(&meta.id).join("source.epub");
    let mut archive = ZipArchive::new(BufReader::new(File::open(source).unwrap())).unwrap();
    archive
        .by_name(&meta.chapters[0].href)
        .expect("first spine item exists in the archive");
}
