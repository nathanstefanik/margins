mod config;
mod epub_meta;
mod library;
mod models;
mod notes;
mod sync;

#[cfg(test)]
mod test_fixtures;

use config::AppConfig;
use library::Library;
use models::{
    BookMeta, BookSummary, ChapterNote, ChapterRef, NoteFrontmatter, NoteSearchHit, SyncReport,
};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, State};

struct AppState {
    config: Mutex<AppConfig>,
    library: Mutex<Library>,
}

#[derive(Clone, Serialize)]
struct ImportProgress {
    percent: u8,
    stage: &'static str,
}

#[tauri::command]
fn get_data_dir(state: State<'_, AppState>) -> Result<String, String> {
    Ok(state
        .config
        .lock()
        .map_err(|e| e.to_string())?
        .data_dir()
        .display()
        .to_string())
}

#[tauri::command]
fn get_library_root(state: State<'_, AppState>) -> Result<String, String> {
    Ok(state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .root()
        .display()
        .to_string())
}

#[tauri::command]
fn list_books(state: State<'_, AppState>) -> Result<Vec<BookSummary>, String> {
    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .list_books()
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn import_epub(
    app: AppHandle,
    state: State<'_, AppState>,
    source_path: String,
) -> Result<BookMeta, String> {
    let mut last_progress: Option<(u8, &'static str)> = None;
    let mut emit_progress = |percent: u8, stage: &'static str| {
        if last_progress == Some((percent, stage)) {
            return;
        }
        last_progress = Some((percent, stage));
        let _ = app.emit("import-progress", ImportProgress { percent, stage });
    };

    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .import_epub_with_progress(PathBuf::from(source_path), |percent, stage| {
            emit_progress(percent, stage);
        })
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn get_book(state: State<'_, AppState>, book_id: String) -> Result<BookMeta, String> {
    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .get_book(&book_id)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn read_epub_bytes(state: State<'_, AppState>, book_id: String) -> Result<Vec<u8>, String> {
    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .read_epub_bytes(&book_id)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn get_chapter_note(
    state: State<'_, AppState>,
    book_id: String,
    chapter_key: String,
) -> Result<ChapterNote, String> {
    let library = state.library.lock().map_err(|e| e.to_string())?;
    notes::load_chapter_note(&library.book_dir(&book_id), &chapter_key).map_err(|e| e.to_string())
}

#[tauri::command]
fn save_chapter_note(
    state: State<'_, AppState>,
    book_id: String,
    chapter: ChapterRef,
    body: String,
    kind: Option<String>,
) -> Result<ChapterNote, String> {
    let library = state.library.lock().map_err(|e| e.to_string())?;
    let book_dir = library.book_dir(&book_id);
    let meta = library.get_book(&book_id).map_err(|e| e.to_string())?;

    let chapter_meta = meta
        .chapters
        .iter()
        .find(|c| c.key == chapter.key)
        .cloned()
        .ok_or_else(|| format!("unknown chapter key: {}", chapter.key))?;

    let frontmatter = NoteFrontmatter {
        book_id: book_id.clone(),
        chapter_key: chapter_meta.key.clone(),
        chapter_index: chapter_meta.index,
        chapter_title: chapter_meta.title.clone(),
        chapter_href: chapter_meta.href.clone(),
        epub_cfi: chapter.epub_cfi,
        kind: kind.unwrap_or_else(|| "summary".into()),
        word_count: notes::count_words(&body),
        created_at: None,
        updated_at: None,
    };

    notes::save_chapter_note(&book_dir, &chapter_meta, frontmatter, &body)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn search_notes(state: State<'_, AppState>, query: String) -> Result<Vec<NoteSearchHit>, String> {
    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .search_notes(&query)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn remove_book(state: State<'_, AppState>, book_id: String) -> Result<(), String> {
    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .remove_book(&book_id)
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn export_library(state: State<'_, AppState>, destination: String) -> Result<SyncReport, String> {
    let root = state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .root()
        .to_path_buf();
    sync::export_library(root, PathBuf::from(destination)).map_err(|e| e.to_string())
}

#[tauri::command]
fn import_library(
    state: State<'_, AppState>,
    source: String,
    merge: bool,
) -> Result<SyncReport, String> {
    let destination = state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .root()
        .to_path_buf();
    let report = sync::import_library(PathBuf::from(source), destination, merge)
        .map_err(|e| e.to_string())?;

    Ok(report)
}

#[tauri::command]
fn set_library_root(state: State<'_, AppState>, path: String) -> Result<String, String> {
    let new_root = PathBuf::from(&path);

    let previous_root = state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .root()
        .to_path_buf();

    state
        .library
        .lock()
        .map_err(|e| e.to_string())?
        .set_root(new_root.clone())
        .map_err(|e| e.to_string())?;

    let config_result = match state.config.lock() {
        Ok(mut config) => config
            .set_library_root(new_root.clone())
            .map_err(|e| e.to_string()),
        Err(error) => Err(error.to_string()),
    };

    if let Err(error) = config_result {
        let restore_result = match state.library.lock() {
            Ok(mut library) => library.set_root(previous_root).map_err(|e| e.to_string()),
            Err(restore_error) => Err(restore_error.to_string()),
        };

        if let Err(restore_error) = restore_result {
            return Err(format!(
                "could not save library directory: {error}; could not restore active directory: {restore_error}"
            ));
        }
        return Err(error);
    }

    Ok(new_root.display().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    dotenvy::dotenv().ok();

    let config = AppConfig::load().expect("failed to load configuration");
    let library = Library::open(config.library_root()).expect("failed to open library");

    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .manage(AppState {
            config: Mutex::new(config),
            library: Mutex::new(library),
        })
        .invoke_handler(tauri::generate_handler![
            get_data_dir,
            get_library_root,
            list_books,
            import_epub,
            get_book,
            read_epub_bytes,
            get_chapter_note,
            save_chapter_note,
            search_notes,
            remove_book,
            export_library,
            import_library,
            set_library_root,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
