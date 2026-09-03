import { ask, open, save } from "@tauri-apps/plugin-dialog";
import { listen } from "@tauri-apps/api/event";
import {
  api,
  type BookMeta,
  type BookSummary,
  type ChapterMeta,
  type CompiledNotes,
  type ExportOptions,
  type ImportProgress,
  type NoteSearchHit,
} from "./api";
import { Keymap } from "./keymaps";
import { EpubReader } from "./reader";

type FileOperation = "import" | "export" | "root";

const DEFAULT_EXPORT_OPTIONS: ExportOptions = {
  include_toc: true,
  include_stats: true,
  include_empty_chapters: false,
  demote_headings: true,
};

export class App {
  private books: BookSummary[] = [];
  private currentBook: BookMeta | null = null;
  private currentChapter: ChapterMeta | null = null;
  private currentCfi: string | undefined;
  private reader: EpubReader;
  private keymap: Keymap;

  private libraryView = document.getElementById("library-view")!;
  private readerView = document.getElementById("reader-view")!;
  private notesView = document.getElementById("notes-view")!;
  private bookList = document.getElementById("book-list")!;
  private chapterList = document.getElementById("chapter-list")!;
  private readerPane = document.getElementById("reader-pane")!;
  private notesEditor = document.getElementById("notes-editor") as HTMLTextAreaElement;
  private notesTitle = document.getElementById("notes-title")!;
  private wordCount = document.getElementById("word-count")!;
  private notesPageTitle = document.getElementById("notes-page-title")!;
  private notesPageStats = document.getElementById("notes-page-stats")!;
  private notesPageBody = document.getElementById("notes-page-body")!;
  private notesPageOutline = document.getElementById("notes-page-outline")!;
  private notesPageOutlineVisible = false;
  private status = document.getElementById("status")!;
  private libraryRoot = document.getElementById("library-root")!;
  private importProgress = document.getElementById("import-progress")!;
  private importProgressBar = document.getElementById("import-progress-bar") as HTMLProgressElement;
  private importProgressLabel = document.getElementById("import-progress-label")!;
  private importProgressPercent = document.getElementById("import-progress-percent")!;
  private commandBar = document.getElementById("command-bar")!;
  private commandInput = document.getElementById("command-input") as HTMLInputElement;
  private searchOverlay = document.getElementById("search-overlay")!;
  private searchInput = document.getElementById("search-input") as HTMLInputElement;
  private searchResults = document.getElementById("search-results")!;
  private searchHits: NoteSearchHit[] = [];
  private searchSelection = 0;
  private searchTimer: number | null = null;
  private searchGen = 0;
  private modeBeforeSearch: "library" | "reader" | "notes" | "notesPage" = "library";
  private fileOperation: FileOperation | null = null;
  private notesData: CompiledNotes | null = null;
  private notesBookId: string | null = null;

  constructor() {
    this.reader = new EpubReader(this.readerPane, (chapter, cfi) => {
      this.currentChapter = chapter;
      this.currentCfi = cfi;
      this.highlightChapter(chapter.key);
      void this.loadNote(chapter);
    }, (event) => this.handleKey(event));

    this.keymap = new Keymap({
      onLibrary: () => void this.showLibrary(),
      onImport: () => void this.importEpub(),
      onExport: () => void this.exportLibrary(),
      onSetRoot: () => void this.setLibraryRoot(),
      onOpenBook: (index) => void this.openBookByIndex(index),
      onScroll: (delta) => this.scrollContent(delta),
      onScrollTop: () => this.scrollContentTop(),
      onScrollBottom: () => this.scrollContentBottom(),
      onNextChapter: () => void this.reader.nextChapter(),
      onPrevChapter: () => void this.reader.prevChapter(),
      onFocusNotes: () => this.focusNotes(),
      onFocusReader: () => this.focusReader(),
      onSaveNote: () => void this.saveNote(),
      onNotesPage: () => void this.openNotesPage(),
      onNotesPageRestore: () => this.showNotesPageView(),
      onNotesClose: () => this.showReaderFromNotes(),
      onNotesToggleView: () => this.showNotesOutline(!this.notesPageOutlineVisible),
      onSearch: (query) => this.showSearch(query),
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
    document.getElementById("btn-search")?.addEventListener("click", () => this.showSearch());
    document.getElementById("btn-all-notes")?.addEventListener("click", () => void this.openNotesPage());
    document.getElementById("btn-copy-notes")?.addEventListener("click", () => void this.copyNotes());
    document.getElementById("btn-export-notes")?.addEventListener("click", () => void this.exportNotes());
    document.getElementById("btn-clear-notes")?.addEventListener("click", () => void this.clearNotes());
    document.getElementById("btn-notes-outline")?.addEventListener("click", () => this.showNotesOutline(true));
    document.getElementById("btn-notes-contents")?.addEventListener("click", () => this.showNotesOutline(false));

    this.notesEditor.addEventListener("input", () => this.updateWordCount());

    this.searchInput.addEventListener("input", () => this.scheduleSearch());
    this.searchInput.addEventListener("keydown", (event) => this.handleSearchKey(event));
    this.searchOverlay.addEventListener("click", (event) => {
      if (event.target === this.searchOverlay) {
        this.closeSearch();
      }
    });

    this.commandInput.addEventListener("keydown", (event) => {
      this.keymap.handleCommandKey(event, this.commandInput);
      if (event.key === "Enter" || event.key === "Escape") {
        this.commandBar.classList.add("hidden");
      }
    });

    window.addEventListener("keydown", (event) => {
      this.handleKey(event);
    });
  }

  private handleKey(event: KeyboardEvent): void {
    this.keymap.handleKey(event, event.target);
    if (this.keymap.getMode() === "library") {
      this.renderLibrarySelection();
    }
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

  private async openBook(bookId: string, chapterKey?: string): Promise<void> {
    this.setStatus("opening book...");
    const meta = await api.getBook(bookId);
    const bytes = await api.readEpubBytes(bookId);
    const uint8 = new Uint8Array(bytes);
    const startIndex = chapterKey
      ? Math.max(0, meta.chapters.findIndex((c) => c.key === chapterKey))
      : 0;

    this.currentBook = meta;
    this.renderChapterList(meta.chapters);
    await this.reader.open(uint8, meta.chapters, startIndex);

    this.libraryView.classList.add("hidden");
    this.notesView.classList.add("hidden");
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
  }

  private showLibrary(): void {
    this.searchOverlay.classList.add("hidden");
    this.reader.destroy();
    this.currentBook = null;
    this.currentChapter = null;
    this.readerView.classList.add("hidden");
    this.notesView.classList.add("hidden");
    this.libraryView.classList.remove("hidden");
    this.keymap.setMode("library");
    void this.refreshLibrary();
    this.setStatus("library");
  }

  // MARK: Notes page

  /// `N` / `:notes` — compiles the current book's notes into one page.
  private async openNotesPage(): Promise<void> {
    if (!this.currentBook) {
      this.setStatus("open a book to see its notes");
      return;
    }
    try {
      this.notesData = await api.getCompiledNotes(this.currentBook.id);
    } catch (error) {
      this.setStatus(`could not compile notes: ${errorMessage(error)}`);
      return;
    }
    this.notesBookId = this.currentBook.id;
    this.renderNotesPage();
    this.showNotesPageView();
  }

  /// Re-shows the already-compiled page (restore after search/command).
  private showNotesPageView(): void {
    if (!this.notesData) return;
    this.libraryView.classList.add("hidden");
    this.readerView.classList.add("hidden");
    this.notesView.classList.remove("hidden");
    this.keymap.setMode("notesPage");
    this.setStatus(`${this.notesData.book_title} — notes`);
  }

  /// `Esc` from the notes page: the reader is still open underneath.
  private showReaderFromNotes(): void {
    this.notesView.classList.add("hidden");
    this.readerView.classList.remove("hidden");
    this.keymap.setMode("reader");
    this.focusReader();
    this.setStatus("reader");
  }

  private renderNotesPage(): void {
    const notes = this.notesData;
    if (!notes) return;

    this.notesPageTitle.textContent = `Notes — ${notes.book_title}`;
    const statParts = [
      `${notes.chapters_with_notes}/${notes.chapter_count} chapters annotated`,
      `${notes.total_words} words`,
    ];
    if (notes.last_updated_at) {
      statParts.push(`last updated ${formatDate(notes.last_updated_at)}`);
    }
    this.notesPageStats.textContent = statParts.join(" · ");

    // Outline view: one entry per annotated chapter. The page opens on
    // the notes view; `t` / the header toggle flip between the two.
    this.notesPageOutline.innerHTML = "";
    if (notes.chapters.length === 0) {
      const empty = document.createElement("li");
      empty.className = "notes-outline-empty";
      empty.textContent = "No notes yet — press `i` in the reader to write one.";
      this.notesPageOutline.appendChild(empty);
    } else {
      for (const chapter of notes.chapters) {
        const li = document.createElement("li");
        const link = document.createElement("a");
        link.href = "#";
        link.textContent = `${chapter.chapter_index + 1}. ${chapter.chapter_title}`;
        link.addEventListener("click", (event) => {
          event.preventDefault();
          this.showNotesOutline(false);
          this.scrollToSection(chapter.chapter_key);
        });
        const meta = document.createElement("span");
        meta.className = "notes-outline-meta";
        const parts = [`${chapter.word_count} words`];
        if (chapter.updated_at) parts.push(`updated ${formatDate(chapter.updated_at)}`);
        meta.textContent = parts.join(" · ");
        li.append(link, meta);
        this.notesPageOutline.appendChild(li);
      }
    }

    // Contents view: sections for chapters that have notes only.
    this.notesPageBody.innerHTML = "";
    if (notes.chapters.length === 0) {
      const empty = document.createElement("p");
      empty.className = "notes-page-empty";
      empty.textContent = "No notes yet — press `i` in the reader to write one.";
      this.notesPageBody.appendChild(empty);
    } else {
      for (const chapter of notes.chapters) {
        this.notesPageBody.appendChild(this.buildNotesSection(chapter));
      }
    }
    this.showNotesOutline(false);
  }

  private showNotesOutline(visible: boolean): void {
    this.notesPageOutlineVisible = visible;
    this.notesPageOutline.classList.toggle("hidden", !visible);
    this.notesPageBody.classList.toggle("hidden", visible);
    document.getElementById("btn-notes-outline")?.classList.toggle("active", visible);
    document.getElementById("btn-notes-contents")?.classList.toggle("active", !visible);
  }

  private buildNotesSection(chapter: CompiledNotes["chapters"][number]): HTMLElement {
    const section = document.createElement("section");
    section.className = "notes-section";
    section.dataset.key = chapter.chapter_key;

    const header = document.createElement("h3");
    header.className = "notes-section-header";
    header.textContent = `${chapter.chapter_index + 1}. ${chapter.chapter_title}`;
    header.addEventListener("click", () => void this.openNotesSection(chapter.chapter_key));
    section.appendChild(header);

    const meta = document.createElement("div");
    meta.className = "notes-section-meta";
    const parts = [`${chapter.word_count} words`];
    if (chapter.updated_at) parts.push(`updated ${formatDate(chapter.updated_at)}`);
    meta.textContent = parts.join(" · ");
    section.appendChild(meta);

    if (chapter.body.trim()) {
      // User markdown stays plain text: textContent only, never innerHTML.
      const body = document.createElement("pre");
      body.className = "notes-section-body";
      body.textContent = chapter.body.trim();
      section.appendChild(body);
    }
    return section;
  }

  private scrollToSection(chapterKey: string): void {
    const section = this.notesPageBody.querySelector(`[data-key="${CSS.escape(chapterKey)}"]`);
    section?.scrollIntoView({ block: "start" });
  }

  /// Clicking a section header opens the reader at that chapter.
  private async openNotesSection(chapterKey: string): Promise<void> {
    const bookId = this.notesBookId;
    if (!bookId) return;
    this.showReaderFromNotes();
    if (this.currentBook?.id === bookId) {
      const idx = this.currentBook.chapters.findIndex((c) => c.key === chapterKey);
      if (idx >= 0) {
        await this.reader.displayChapter(idx);
      }
    } else {
      await this.openBook(bookId, chapterKey);
    }
  }

  private async copyNotes(): Promise<void> {
    if (!this.notesBookId) return;
    try {
      const markdown = await api.renderNotesMarkdown(this.notesBookId, DEFAULT_EXPORT_OPTIONS);
      await navigator.clipboard.writeText(markdown);
      this.setStatus("markdown copied to clipboard");
    } catch (error) {
      this.setStatus(`copy failed: ${errorMessage(error)}`);
    }
  }

  private async exportNotes(): Promise<void> {
    if (!this.notesBookId || !this.notesData) return;
    const destination = await save({
      defaultPath: this.notesData.suggested_filename,
      filters: [{ name: "Markdown", extensions: ["md"] }],
    });
    if (!destination) return;
    try {
      const path = await api.exportNotesMarkdown(
        this.notesBookId,
        destination,
        DEFAULT_EXPORT_OPTIONS,
      );
      this.setStatus(`exported ${path}`);
    } catch (error) {
      this.setStatus(`export failed: ${errorMessage(error)}`);
    }
  }

  /// Deletes every note for the book behind the notes page, after an
  /// explicit confirmation. The reader's open note editor is reloaded so a
  /// stale body cannot resurrect a cleared note on the next save.
  private async clearNotes(): Promise<void> {
    if (!this.notesBookId || !this.notesData) return;
    if (this.notesData.chapters.length === 0) {
      this.setStatus("no notes to clear");
      return;
    }
    const count = this.notesData.chapters.length;
    const confirmed = await ask(
      `Delete all ${count} chapter note${count === 1 ? "" : "s"} for “${this.notesData.book_title}”? This cannot be undone.`,
      {
        title: "Clear all notes",
        kind: "warning",
        okLabel: "Clear Notes",
        cancelLabel: "Keep Notes",
      },
    );
    if (!confirmed) return;
    const bookId = this.notesBookId;
    try {
      const removed = await api.clearBookNotes(bookId);
      await this.refreshLibrary();
      if (this.currentBook?.id === bookId && this.currentChapter) {
        await this.loadNote(this.currentChapter);
      }
      await this.openNotesPage();
      this.setStatus(`cleared ${removed} note${removed === 1 ? "" : "s"}`);
    } catch (error) {
      this.setStatus(`could not clear notes: ${errorMessage(error)}`);
    }
  }

  /// `j`/`k` scroll the reader pane normally, but the notes page when it
  /// is the visible content.
  private scrollContent(delta: number): void {
    if (this.keymap.getMode() === "notesPage") {
      this.notesView.scrollBy({ top: delta });
    } else {
      this.reader.scrollBy(delta);
    }
  }

  private scrollContentTop(): void {
    if (this.keymap.getMode() === "notesPage") {
      this.notesView.scrollTo({ top: 0 });
    } else {
      this.reader.scrollToTop();
    }
  }

  private scrollContentBottom(): void {
    if (this.keymap.getMode() === "notesPage") {
      this.notesView.scrollTo({ top: this.notesView.scrollHeight });
    } else {
      this.reader.scrollToBottom();
    }
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

  private showSearch(query = ""): void {
    const mode = this.keymap.getMode();
    if (mode === "library" || mode === "reader" || mode === "notes" || mode === "notesPage") {
      this.modeBeforeSearch = mode;
    }
    this.commandBar.classList.add("hidden");
    this.searchOverlay.classList.remove("hidden");
    this.keymap.setMode("search");
    this.searchInput.value = query;
    this.searchInput.focus();
    this.searchInput.select();
    if (query.trim()) {
      void this.runSearch(query);
    } else {
      this.searchHits = [];
      this.searchSelection = 0;
      this.renderSearchResults();
    }
  }

  private closeSearch(): void {
    this.searchOverlay.classList.add("hidden");
    this.searchGen += 1;
    if (this.searchTimer !== null) {
      window.clearTimeout(this.searchTimer);
      this.searchTimer = null;
    }
    if (this.modeBeforeSearch === "library") {
      this.keymap.setMode("library");
    } else if (this.modeBeforeSearch === "notes") {
      this.focusNotes();
    } else if (this.modeBeforeSearch === "notesPage") {
      this.showNotesPageView();
    } else {
      this.focusReader();
    }
  }

  private scheduleSearch(): void {
    if (this.searchTimer !== null) {
      window.clearTimeout(this.searchTimer);
    }
    this.searchTimer = window.setTimeout(() => {
      this.searchTimer = null;
      void this.runSearch(this.searchInput.value);
    }, 120);
  }

  private async runSearch(query: string): Promise<void> {
    const gen = ++this.searchGen;
    const trimmed = query.trim();
    if (!trimmed) {
      this.searchHits = [];
      this.searchSelection = 0;
      this.renderSearchResults();
      this.setStatus("search notes");
      return;
    }
    const hits = await api.searchNotes(trimmed);
    if (gen !== this.searchGen) return;
    this.searchHits = hits;
    this.searchSelection = 0;
    this.renderSearchResults();
    this.setStatus(
      this.searchHits.length === 0
        ? `no notes match “${trimmed}”`
        : `${this.searchHits.length} note${this.searchHits.length === 1 ? "" : "s"}`,
    );
  }

  private renderSearchResults(): void {
    this.searchResults.innerHTML = "";
    if (this.searchHits.length === 0) {
      const empty = document.createElement("li");
      empty.className = "search-empty";
      empty.textContent = this.searchInput.value.trim() ? "no matches" : "type to search notes";
      this.searchResults.appendChild(empty);
      return;
    }

    const query = this.searchInput.value;
    this.searchHits.forEach((hit, index) => {
      const li = document.createElement("li");
      li.classList.toggle("selected", index === this.searchSelection);
      li.innerHTML = `
        <span class="search-hit-title">${escapeHtml(hit.book_title)} — ${escapeHtml(hit.chapter_title)}</span>
        <span class="search-hit-meta">${escapeHtml(hit.book_author)} · ${hit.word_count} words</span>
        <span class="search-hit-snippet">${highlightSnippet(hit.snippet, query)}</span>
      `;
      li.addEventListener("click", () => void this.openSearchHit(hit));
      this.searchResults.appendChild(li);
    });
    this.searchResults.querySelectorAll("li")[this.searchSelection]?.scrollIntoView({
      block: "nearest",
    });
  }

  private moveSearchSelection(delta: number): void {
    if (this.searchHits.length === 0) return;
    this.searchSelection =
      (this.searchSelection + delta + this.searchHits.length) % this.searchHits.length;
    this.renderSearchResults();
  }

  private handleSearchKey(event: KeyboardEvent): void {
    if (event.key === "Escape") {
      event.preventDefault();
      this.closeSearch();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const hit = this.searchHits[this.searchSelection];
      if (hit) void this.openSearchHit(hit);
      return;
    }
    if (event.key === "ArrowDown" || (event.ctrlKey && event.key === "n")) {
      event.preventDefault();
      this.moveSearchSelection(1);
      return;
    }
    if (event.key === "ArrowUp" || (event.ctrlKey && event.key === "p")) {
      event.preventDefault();
      this.moveSearchSelection(-1);
    }
  }

  private async openSearchHit(hit: NoteSearchHit): Promise<void> {
    this.searchOverlay.classList.add("hidden");
    this.searchGen += 1;
    if (this.searchTimer !== null) {
      window.clearTimeout(this.searchTimer);
      this.searchTimer = null;
    }

    if (this.currentBook?.id === hit.book_id) {
      const idx = this.currentBook.chapters.findIndex((c) => c.key === hit.chapter_key);
      if (idx >= 0) {
        await this.reader.displayChapter(idx);
      }
      this.keymap.setMode("reader");
      this.focusReader();
      this.setStatus(`${hit.book_title} — ${hit.chapter_title}`);
      return;
    }

    await this.openBook(hit.book_id, hit.chapter_key);
    this.setStatus(`${hit.book_title} — ${hit.chapter_title}`);
  }

  private async importEpub(): Promise<void> {
    if (this.fileOperation) return;

    this.fileOperation = "import";
    this.setFileOperationsBusy(true);

    let unlisten: (() => void) | undefined;
    try {
      const selected = await open({
        multiple: false,
        filters: [{ name: "EPUB", extensions: ["epub"] }],
      });
      if (!selected || Array.isArray(selected)) return;

      this.showImportProgress();
      unlisten = await listen<ImportProgress>("import-progress", (event) => {
        this.updateImportProgress(event.payload);
      });
      this.setStatus("importing...");
      const meta = await api.importEpub(selected);
      await this.refreshLibrary();
      this.updateImportProgress({ percent: 100, stage: "complete" });
      this.setStatus(`imported ${meta.title}`);
      await this.openBook(meta.id);
    } catch (error) {
      this.setStatus(`import failed: ${errorMessage(error)}`);
    } finally {
      unlisten?.();
      this.fileOperation = null;
      this.setFileOperationsBusy(false);
      this.importProgress.classList.add("hidden");
    }
  }

  private showImportProgress(): void {
    this.importProgress.classList.remove("hidden");
    this.updateImportProgress({ percent: 0, stage: "preparing" });
  }

  private updateImportProgress(progress: ImportProgress): void {
    const percent = Math.max(0, Math.min(100, Math.round(progress.percent)));
    const labels: Record<string, string> = {
      preparing: "Preparing EPUB",
      "reading-metadata": "Reading metadata",
      hashing: "Checking file",
      copying: "Copying EPUB",
      saving: "Saving to library",
      "already-imported": "Already in library",
      complete: "Import complete",
    };
    this.importProgressBar.value = percent;
    this.importProgressBar.textContent = `${percent}%`;
    this.importProgressPercent.textContent = `${percent}%`;
    this.importProgressLabel.textContent = labels[progress.stage] ?? progress.stage;
  }

  private setFileOperationsBusy(busy: boolean): void {
    ["btn-import", "btn-export", "btn-set-root"].forEach((id) => {
      const button = document.getElementById(id) as HTMLButtonElement | null;
      if (button) button.disabled = busy;
    });
  }

  private async exportLibrary(): Promise<void> {
    if (this.fileOperation) return;
    this.fileOperation = "export";
    this.setFileOperationsBusy(true);

    try {
      const destination = await open({ directory: true, multiple: false });
      if (!destination || Array.isArray(destination)) return;

      this.setStatus("exporting library...");
      const report = await api.exportLibrary(destination);
      this.setStatus(`exported ${report.files_copied} files`);
    } catch (error) {
      this.setStatus(`export failed: ${errorMessage(error)}`);
    } finally {
      this.fileOperation = null;
      this.setFileOperationsBusy(false);
    }
  }

  private async setLibraryRoot(): Promise<void> {
    if (this.fileOperation) return;
    this.fileOperation = "root";
    this.setFileOperationsBusy(true);

    try {
      const path = await open({ directory: true, multiple: false });
      if (!path || Array.isArray(path)) return;

      this.setStatus("setting library directory...");
      const root = await api.setLibraryRoot(path);
      this.libraryRoot.textContent = root;
      this.searchOverlay.classList.add("hidden");
      this.commandBar.classList.add("hidden");
      this.searchGen += 1;
      if (this.searchTimer !== null) {
        window.clearTimeout(this.searchTimer);
        this.searchTimer = null;
      }

      // A book opened from the previous directory is no longer the active book.
      this.reader.destroy();
      this.currentBook = null;
      this.currentChapter = null;
      this.currentCfi = undefined;
      this.readerView.classList.add("hidden");
      this.notesView.classList.add("hidden");
      this.libraryView.classList.remove("hidden");
      this.keymap.setMode("library");

      await this.refreshLibrary();
      this.setStatus("library directory set");
    } catch (error) {
      this.setStatus(`could not set library directory: ${errorMessage(error)}`);
    } finally {
      this.fileOperation = null;
      this.setFileOperationsBusy(false);
    }
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

function formatDate(rfc3339: string): string {
  const date = new Date(rfc3339);
  if (Number.isNaN(date.getTime())) return rfc3339;
  return date.toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric" });
}

function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function highlightSnippet(snippet: string, query: string): string {
  const escaped = escapeHtml(snippet);
  const terms = query
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map(escapeHtml)
    .sort((a, b) => b.length - a.length);
  let result = escaped;
  for (const term of terms) {
    const re = new RegExp(escapeRegex(term), "gi");
    result = result.replace(re, (match) => `<mark>${match}</mark>`);
  }
  return result;
}

function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message;
  if (typeof error === "string") return error;
  return "unknown error";
}
