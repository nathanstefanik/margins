type Mode = "library" | "reader" | "notes" | "command";

export interface KeymapHandlers {
  onLibrary: () => void;
  onImport: () => void;
  onExport: () => void;
  onSetRoot: () => void;
  onOpenBook: (index: number) => void;
  onScroll: (delta: number) => void;
  onScrollTop: () => void;
  onScrollBottom: () => void;
  onNextChapter: () => void;
  onPrevChapter: () => void;
  onFocusNotes: () => void;
  onFocusReader: () => void;
  onSaveNote: () => void;
  onCommand: (cmd: string) => void;
  onStatus: (msg: string) => void;
}

export class Keymap {
  private mode: Mode = "library";
  private librarySelection = 0;
  private bookCount = 0;

  constructor(private handlers: KeymapHandlers) {}

  setMode(mode: Mode): void {
    this.mode = mode;
  }

  getMode(): Mode {
    return this.mode;
  }

  setBookCount(count: number): void {
    this.bookCount = count;
    if (this.librarySelection >= count) {
      this.librarySelection = Math.max(0, count - 1);
    }
  }

  getLibrarySelection(): number {
    return this.librarySelection;
  }

  setLibrarySelection(index: number): void {
    this.librarySelection = Math.max(0, Math.min(index, this.bookCount - 1));
  }

  handleKey(event: KeyboardEvent, target: EventTarget | null): void {
    if (this.mode === "command") {
      return;
    }

    const tag = target instanceof HTMLElement ? target.tagName : "";
    const typing = tag === "INPUT" || tag === "TEXTAREA";

    if (this.mode === "notes" && typing) {
      if (event.key === "Escape") {
        event.preventDefault();
        this.handlers.onFocusReader();
      }
      if (event.ctrlKey && event.key === "s") {
        event.preventDefault();
        this.handlers.onSaveNote();
      }
      return;
    }

    if (typing) {
      return;
    }

    if (event.key === ":") {
      event.preventDefault();
      this.mode = "command";
      this.handlers.onCommand("");
      return;
    }

    switch (event.key) {
      case "j":
        event.preventDefault();
        if (this.mode === "library") {
          this.librarySelection = Math.min(this.librarySelection + 1, this.bookCount - 1);
          this.handlers.onStatus(`select ${this.librarySelection + 1}`);
        } else {
          this.handlers.onScroll(80);
        }
        break;
      case "k":
        event.preventDefault();
        if (this.mode === "library") {
          this.librarySelection = Math.max(this.librarySelection - 1, 0);
          this.handlers.onStatus(`select ${this.librarySelection + 1}`);
        } else {
          this.handlers.onScroll(-80);
        }
        break;
      case "g":
        if (event.repeat) break;
        this.pendingG = true;
        break;
      case "G":
        event.preventDefault();
        this.handlers.onScrollBottom();
        break;
      case "n":
        event.preventDefault();
        this.handlers.onNextChapter();
        break;
      case "p":
        event.preventDefault();
        this.handlers.onPrevChapter();
        break;
      case "i":
        event.preventDefault();
        this.handlers.onFocusNotes();
        break;
      case "l":
        event.preventDefault();
        this.handlers.onLibrary();
        break;
      case "o":
        event.preventDefault();
        this.handlers.onImport();
        break;
      case "E":
        event.preventDefault();
        this.handlers.onExport();
        break;
      case "R":
        event.preventDefault();
        this.handlers.onSetRoot();
        break;
      case "Enter":
        if (this.mode === "library") {
          event.preventDefault();
          this.handlers.onOpenBook(this.librarySelection);
        }
        break;
      case "Escape":
        event.preventDefault();
        this.handlers.onFocusReader();
        break;
      default:
        if (this.pendingG && event.key === "g") {
          event.preventDefault();
          this.pendingG = false;
          this.handlers.onScrollTop();
        } else {
          this.pendingG = false;
        }
    }
  }

  handleCommandKey(event: KeyboardEvent, input: HTMLInputElement): void {
    if (event.key === "Escape") {
      event.preventDefault();
      this.mode = "reader";
      this.handlers.onFocusReader();
      return;
    }

    if (event.key === "Enter") {
      event.preventDefault();
      const cmd = input.value.trim();
      this.mode = "reader";
      this.runCommand(cmd);
      this.handlers.onFocusReader();
    }
  }

  private pendingG = false;

  private runCommand(cmd: string): void {
    switch (cmd) {
      case "w":
        this.handlers.onSaveNote();
        break;
      case "q":
        this.handlers.onLibrary();
        break;
      case "import":
        this.handlers.onImport();
        break;
      case "export":
        this.handlers.onExport();
        break;
      case "root":
        this.handlers.onSetRoot();
        break;
      default:
        if (cmd.startsWith("open ")) {
          const n = Number.parseInt(cmd.slice(5), 10);
          if (!Number.isNaN(n)) {
            this.handlers.onOpenBook(n - 1);
          }
        } else if (cmd) {
          this.handlers.onStatus(`unknown command: ${cmd}`);
        }
    }
  }
}
