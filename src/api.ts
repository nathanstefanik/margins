import { invoke } from "@tauri-apps/api/core";

export interface BookSummary {
  id: string;
  title: string;
  author: string;
  added_at: string;
  chapter_count: number;
  notes_count: number;
}

export interface ChapterMeta {
  key: string;
  index: number;
  title: string;
  href: string;
}

export interface BookMeta {
  id: string;
  title: string;
  author: string;
  language?: string;
  added_at: string;
  source_filename: string;
  chapters: ChapterMeta[];
}

export interface ChapterNote {
  frontmatter: {
    book_id: string;
    chapter_key: string;
    chapter_index: number;
    chapter_title: string;
    chapter_href: string;
    epub_cfi?: string;
    kind: string;
    word_count: number;
    created_at?: string;
    updated_at?: string;
  };
  body: string;
  path: string;
}

export interface SyncReport {
  files_copied: number;
  bytes_copied: number;
  destination: string;
}

export const api = {
  getDataDir: () => invoke<string>("get_data_dir"),
  getLibraryRoot: () => invoke<string>("get_library_root"),
  listBooks: () => invoke<BookSummary[]>("list_books"),
  importEpub: (sourcePath: string) => invoke<BookMeta>("import_epub", { sourcePath }),
  getBook: (bookId: string) => invoke<BookMeta>("get_book", { bookId }),
  readEpubBytes: (bookId: string) => invoke<number[]>("read_epub_bytes", { bookId }),
  getChapterNote: (bookId: string, chapterKey: string) =>
    invoke<ChapterNote>("get_chapter_note", { bookId, chapterKey }),
  saveChapterNote: (bookId: string, chapter: { key: string; epub_cfi?: string }, body: string) =>
    invoke<ChapterNote>("save_chapter_note", {
      bookId,
      chapter,
      body,
      kind: "summary",
    }),
  removeBook: (bookId: string) => invoke<void>("remove_book", { bookId }),
  exportLibrary: (destination: string) =>
    invoke<SyncReport>("export_library", { destination }),
  importLibrary: (source: string, merge: boolean) =>
    invoke<SyncReport>("import_library", { source, merge }),
  setLibraryRoot: (path: string) => invoke<string>("set_library_root", { path }),
};
