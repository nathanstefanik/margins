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
  /** In-zip path of the spine item; never carries a fragment. */
  href: string;
  /** Anchor id where the chapter starts inside `href`, from the book's TOC. */
  fragment?: string | null;
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

export interface Mark {
  id: string;
  /** Range CFI of the selection, or null for a page-anchored mark. */
  cfi?: string | null;
  at: string;
  percent?: number | null;
  quote: string;
  body: string;
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
  marks: Mark[];
  path: string;
}

export interface SyncReport {
  files_copied: number;
  bytes_copied: number;
  destination: string;
}

export interface NoteSearchHit {
  book_id: string;
  book_title: string;
  book_author: string;
  chapter_key: string;
  chapter_index: number;
  chapter_title: string;
  snippet: string;
  word_count: number;
}

export interface CompiledChapter {
  chapter_key: string;
  chapter_index: number;
  chapter_title: string;
  body: string;
  marks: Mark[];
  word_count: number;
  updated_at?: string;
}

export interface CompiledNotes {
  book_id: string;
  book_title: string;
  book_author: string;
  chapters: CompiledChapter[];
  empty_chapters: CompiledChapter[];
  chapters_with_notes: number;
  chapter_count: number;
  total_words: number;
  first_created_at?: string;
  last_updated_at?: string;
  suggested_filename: string;
}

export interface ExportOptions {
  include_toc: boolean;
  include_stats: boolean;
  include_empty_chapters: boolean;
  demote_headings: boolean;
}

export interface ImportProgress {
  percent: number;
  stage: string;
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
  appendMark: (
    bookId: string,
    chapterKey: string,
    mark: { cfi?: string | null; percent?: number | null; quote: string; body: string },
  ) => invoke<Mark>("append_mark", { bookId, chapterKey, ...mark }),
  updateMark: (bookId: string, chapterKey: string, mark: Mark) =>
    invoke<void>("update_mark", { bookId, chapterKey, mark }),
  deleteMark: (bookId: string, chapterKey: string, markId: string) =>
    invoke<void>("delete_mark", { bookId, chapterKey, markId }),
  searchNotes: (query: string) => invoke<NoteSearchHit[]>("search_notes", { query }),
  getCompiledNotes: (bookId: string) => invoke<CompiledNotes>("get_compiled_notes", { bookId }),
  exportNotesMarkdown: (bookId: string, destination: string, options?: ExportOptions) =>
    invoke<string>("export_notes_markdown", { bookId, destination, options }),
  renderNotesMarkdown: (bookId: string, options?: ExportOptions) =>
    invoke<string>("render_notes_markdown", { bookId, options }),
  removeBook: (bookId: string) => invoke<void>("remove_book", { bookId }),
  clearBookNotes: (bookId: string) => invoke<number>("clear_book_notes", { bookId }),
  exportLibrary: (destination: string) =>
    invoke<SyncReport>("export_library", { destination }),
  importLibrary: (source: string, merge: boolean) =>
    invoke<SyncReport>("import_library", { source, merge }),
  setLibraryRoot: (path: string) => invoke<string>("set_library_root", { path }),
};
