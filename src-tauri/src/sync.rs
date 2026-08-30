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
