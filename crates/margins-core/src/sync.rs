use crate::models::SyncReport;
use std::fs;
use std::path::{Path, PathBuf};
use thiserror::Error;
use walkdir::WalkDir;

#[derive(Debug, Error)]
pub enum SyncError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("{0}")]
    Other(String),
}

pub fn export_library(source: PathBuf, destination: PathBuf) -> Result<SyncReport, SyncError> {
    copy_tree(&source, &destination, false)
}

pub fn import_library(
    source: PathBuf,
    destination: PathBuf,
    merge: bool,
) -> Result<SyncReport, SyncError> {
    if !source.exists() {
        return Err(SyncError::Other("source library does not exist".into()));
    }
    copy_tree(&source, &destination, merge)
}

fn copy_tree(source: &Path, destination: &Path, merge: bool) -> Result<SyncReport, SyncError> {
    fs::create_dir_all(destination)?;

    let mut files_copied = 0usize;
    let mut bytes_copied = 0u64;

    for entry in WalkDir::new(source).into_iter().filter_map(Result::ok) {
        let src_path = entry.path();
        let rel = src_path
            .strip_prefix(source)
            .map_err(|e| SyncError::Other(e.to_string()))?;
        let dest_path = destination.join(rel);

        if src_path.is_dir() {
            fs::create_dir_all(&dest_path)?;
            continue;
        }

        if merge && dest_path.exists() {
            let src_meta = fs::metadata(src_path)?;
            let dest_meta = fs::metadata(&dest_path)?;
            if let (Ok(src_mod), Ok(dest_mod)) = (src_meta.modified(), dest_meta.modified()) {
                if dest_mod >= src_mod {
                    continue;
                }
            }
        }

        if let Some(parent) = dest_path.parent() {
            fs::create_dir_all(parent)?;
        }

        let bytes = fs::copy(src_path, &dest_path)?;
        files_copied += 1;
        bytes_copied += bytes;
    }

    Ok(SyncReport {
        files_copied,
        bytes_copied,
        destination: destination.display().to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, SystemTime};

    #[test]
    fn export_copies_library_tree() {
        let tmp = tempfile::tempdir().unwrap();
        let source = tmp.path().join("src");
        let dest = tmp.path().join("dest");
        fs::create_dir_all(source.join("books/one")).unwrap();
        fs::write(source.join("index.json"), r#"{"books":[]}"#).unwrap();
        fs::write(source.join("books/one/meta.json"), r#"{"id":"one"}"#).unwrap();

        let report = export_library(source, dest.clone()).unwrap();
        assert_eq!(report.files_copied, 2);
        assert!(dest.join("index.json").exists());
        assert!(dest.join("books/one/meta.json").exists());
    }

    #[test]
    fn merge_skips_newer_destination_files() {
        let tmp = tempfile::tempdir().unwrap();
        let source = tmp.path().join("src");
        let dest = tmp.path().join("dest");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&dest).unwrap();
        fs::write(source.join("note.md"), "old").unwrap();
        fs::write(dest.join("note.md"), "newer-on-dest").unwrap();

        let now = SystemTime::now();
        let past = now - Duration::from_secs(60);
        filetime_set(source.join("note.md"), past);
        filetime_set(dest.join("note.md"), now);

        let report = import_library(source, dest.clone(), true).unwrap();
        assert_eq!(report.files_copied, 0);
        assert_eq!(
            fs::read_to_string(dest.join("note.md")).unwrap(),
            "newer-on-dest"
        );
    }

    #[test]
    fn import_missing_source_errors() {
        let tmp = tempfile::tempdir().unwrap();
        let err = import_library(tmp.path().join("missing"), tmp.path().join("dest"), false);
        assert!(err.is_err());
    }

    fn filetime_set(path: PathBuf, time: SystemTime) {
        let file = fs::File::options().write(true).open(path).unwrap();
        file.set_modified(time).unwrap();
    }
}
