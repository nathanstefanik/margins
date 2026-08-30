import { open } from "@tauri-apps/plugin-dialog";
import { api, type BookMeta, type BookSummary, type ChapterMeta } from "./api";
import { Keymap } from "./keymaps";
import { EpubReader } from "./reader";

export class App {
  private books: BookSummary[] = [];
  private currentBook: BookMeta | null = null;
  private currentChapter: ChapterMeta | null = null;
  private currentCfi: string | undefined;
  private reader: EpubReader;
  private keymap: Keymap;

  private libraryView = document.getElementById("library-view")!;
  private readerView = document.getElementById("reader-view")!;
  private bookList = document.getElementById("book-list")!;
  private chapterList = document.getElementById("chapter-list")!;
  private readerPane = document.getElementById("reader-pane")!;
  private notesEditor = document.getElementById("notes-editor") as HTMLTextAreaElement;
  private notesTitle = document.getElementById("notes-title")!;
  private wordCount = document.getElementById("word-count")!;
  private status = document.getElementById("status")!;
  private libraryRoot = document.getElementById("library-root")!;
  private commandBar = document.getElementById("command-bar")!;
  private commandInput = document.getElementById("command-input") as HTMLInputElement;

  constructor() {
    this.reader = new EpubReader(this.readerPane, (chapter, cfi) => {
      this.currentChapter = chapter;
      this.currentCfi = cfi;
      this.highlightChapter(chapter.key);
      void this.loadNote(chapter);
    });

    this.keymap = new Keymap({
      onLibrary: () => void this.showLibrary(),
      onImport: () => void this.importEpub(),
      onExport: () => void this.exportLibrary(),
      onSetRoot: () => void this.setLibraryRoot(),
      onOpenBook: (index) => void this.openBookByIndex(index),
      onScroll: (delta) => this.reader.scrollBy(delta),
      onScrollTop: () => this.reader.scrollToTop(),
      onScrollBottom: () => this.reader.scrollToBottom(),
      onNextChapter: () => void this.reader.nextChapter(),
      onPrevChapter: () => void this.reader.prevChapter(),
      onFocusNotes: () => this.focusNotes(),
      onFocusReader: () => this.focusReader(),
      onSaveNote: () => void this.saveNote(),
      onCommand: (cmd) => this.showCommand(cmd),
      onStatus: (msg) => this.setStatus(msg),
    });

    this.wireUi();
    void this.bootstrap();
  }

  private wireUi(): void {
    document.getElementById("btn-library")?.addEventListener("click", () => void this.showLibrary());
    document.getElementById("btn-import")?.addEventListener("click", () => void this.importEpub());
    document.getElementById("btn-export")?.addEventListener("click", () => void this.exportLibrary());
    document.getElementById("btn-set-root")?.addEventListener("click", () => void this.setLibraryRoot());
    document.getElementById("btn-save-note")?.addEventListener("click", () => void this.saveNote());

    this.notesEditor.addEventListener("input", () => this.updateWordCount());

    this.commandInput.addEventListener("keydown", (event) => {
      this.keymap.handleCommandKey(event, this.commandInput);
      if (event.key === "Enter" || event.key === "Escape") {
        this.commandBar.classList.add("hidden");
      }
    });

    window.addEventListener("keydown", (event) => {
      this.keymap.handleKey(event, event.target);
      if (this.keymap.getMode() === "library") {
        this.renderLibrarySelection();
      }
    });
  }

  private async bootstrap(): Promise<void> {
    const root = await api.getLibraryRoot();
    this.libraryRoot.textContent = root;
    await this.refreshLibrary();
    this.showLibrary();
  }

  private async refreshLibrary(): Promise<void> {
    this.books = await api.listBooks();
    this.keymap.setBookCount(this.books.length);
    this.renderBookList();
  }

  private renderBookList(): void {
    this.bookList.innerHTML = "";
    this.books.forEach((book, index) => {
      const li = document.createElement("li");
      li.dataset.index = String(index);
      li.innerHTML = `
        <span class="book-title">${escapeHtml(book.title)}</span>
        <span class="book-meta">${escapeHtml(book.author)} · ${book.notes_count}/${book.chapter_count} notes</span>
      `;
      li.addEventListener("click", () => void this.openBook(book.id));
      li.addEventListener("dblclick", () => void this.openBook(book.id));
      this.bookList.appendChild(li);
    });
    this.renderLibrarySelection();
  }

  private renderLibrarySelection(): void {
    const items = this.bookList.querySelectorAll("li");
    const selected = this.keymap.getLibrarySelection();
    items.forEach((item, index) => {
      item.classList.toggle("selected", index === selected);
    });
    const selectedItem = items[selected];
    selectedItem?.scrollIntoView({ block: "nearest" });
  }

  private async openBookByIndex(index: number): Promise<void> {
    const book = this.books[index];
    if (book) {
      await this.openBook(book.id);
    }
  }

  private async openBook(bookId: string): Promise<void> {
    this.setStatus("opening book...");
    const meta = await api.getBook(bookId);
    const bytes = await api.readEpubBytes(bookId);
    const uint8 = new Uint8Array(bytes);

    this.currentBook = meta;
    this.renderChapterList(meta.chapters);
    await this.reader.open(uint8, meta.chapters);

    this.libraryView.classList.add("hidden");
    this.readerView.classList.remove("hidden");
    this.keymap.setMode("reader");
    this.focusReader();
    this.setStatus(`${meta.title} — ${meta.author}`);
  }

  private renderChapterList(chapters: ChapterMeta[]): void {
    this.chapterList.innerHTML = "";
    chapters.forEach((chapter, index) => {
      const btn = document.createElement("button");
      btn.className = "chapter-item";
      btn.dataset.key = chapter.key;
      btn.textContent = `${index + 1}. ${chapter.title}`;
      btn.addEventListener("click", () => void this.reader.displayChapter(index));
      this.chapterList.appendChild(btn);
    });
  }

  private highlightChapter(key: string): void {
    this.chapterList.querySelectorAll(".chapter-item").forEach((el) => {
      el.classList.toggle("active", (el as HTMLElement).dataset.key === key);
    });
  }

  private async loadNote(chapter: ChapterMeta): Promise<void> {
    if (!this.currentBook) return;
    const note = await api.getChapterNote(this.currentBook.id, chapter.key);
    this.notesEditor.value = note.body;
    this.notesTitle.textContent = `${chapter.title} — notes`;
    this.updateWordCount();
  }

  private async saveNote(): Promise<void> {
    if (!this.currentBook || !this.currentChapter) {
      this.setStatus("no chapter selected");
      return;
    }
    const saved = await api.saveChapterNote(
      this.currentBook.id,
      { key: this.currentChapter.key, epub_cfi: this.currentCfi },
      this.notesEditor.value,
    );
    this.updateWordCount(saved.frontmatter.word_count);
    this.setStatus(`saved note (${saved.frontmatter.word_count} words)`);
    await this.refreshLibrary();
  }

  private updateWordCount(count?: number): void {
    const words = count ?? this.notesEditor.value.trim().split(/\s+/).filter(Boolean).length;
    this.wordCount.textContent = `${words} words`;
    this.wordCount.classList.toggle("warn", words > 0 && (words < 80 || words > 120));
  }

  private showLibrary(): void {
    this.reader.destroy();
    this.currentBook = null;
    this.currentChapter = null;
    this.readerView.classList.add("hidden");
    this.libraryView.classList.remove("hidden");
    this.keymap.setMode("library");
    void this.refreshLibrary();
    this.setStatus("library");
  }

  private focusNotes(): void {
    this.keymap.setMode("notes");
    this.notesEditor.focus();
  }

  private focusReader(): void {
    this.keymap.setMode("reader");
    this.commandBar.classList.add("hidden");
    this.readerPane.focus();
  }

  private showCommand(prefill: string): void {
    this.commandBar.classList.remove("hidden");
    this.commandInput.value = prefill;
    this.commandInput.focus();
  }

  private async importEpub(): Promise<void> {
    const selected = await open({
      multiple: false,
      filters: [{ name: "EPUB", extensions: ["epub"] }],
    });
    if (!selected || Array.isArray(selected)) return;

    this.setStatus("importing...");
    const meta = await api.importEpub(selected);
    await this.refreshLibrary();
    this.setStatus(`imported ${meta.title}`);
    await this.openBook(meta.id);
  }

  private async exportLibrary(): Promise<void> {
    const destination = await open({ directory: true, multiple: false });
    if (!destination || Array.isArray(destination)) return;

    this.setStatus("exporting library...");
    const report = await api.exportLibrary(destination);
    this.setStatus(`exported ${report.files_copied} files`);
  }

  private async setLibraryRoot(): Promise<void> {
    const path = await open({ directory: true, multiple: false });
    if (!path || Array.isArray(path)) return;

    const root = await api.setLibraryRoot(path);
    this.libraryRoot.textContent = root;
    await this.refreshLibrary();
    this.setStatus(`library root set`);
  }

  private setStatus(message: string): void {
    this.status.textContent = message;
  }
}

function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
