import ePub, { Book, Rendition } from "epubjs";
import type { ChapterMeta } from "./api";

export class EpubReader {
  private book: Book | null = null;
  private rendition: Rendition | null = null;
  private chapters: ChapterMeta[] = [];
  private chapterIndex = 0;

  constructor(
    private container: HTMLElement,
    private onChapterChange: (chapter: ChapterMeta, cfi?: string) => void,
  ) {}

  async open(bytes: Uint8Array, chapters: ChapterMeta[], startIndex = 0): Promise<void> {
    this.destroy();
    this.chapters = chapters;
    this.chapterIndex = 0;

    this.book = ePub(bytes.buffer);
    await this.book.ready;

    this.rendition = this.book.renderTo(this.container, {
      width: "100%",
      height: "100%",
      flow: "paginated",
      spread: "none",
    });

    this.rendition.on("relocated", (location: { start: { cfi: string } }) => {
      const cfi = location.start.cfi;
      const current = this.chapters[this.chapterIndex];
      if (current) {
        this.onChapterChange(current, cfi);
      }
    });

    if (chapters[startIndex]) {
      await this.displayChapter(startIndex);
    } else if (chapters[0]) {
      await this.displayChapter(0);
    }
  }

  async displayChapter(index: number): Promise<void> {
    if (!this.rendition || !this.book || index < 0 || index >= this.chapters.length) {
      return;
    }
    this.chapterIndex = index;
    const chapter = this.chapters[index];
    await this.rendition.display(chapter.href);
    this.onChapterChange(chapter);
  }

  async nextChapter(): Promise<void> {
    await this.displayChapter(this.chapterIndex + 1);
  }

  async prevChapter(): Promise<void> {
    await this.displayChapter(this.chapterIndex - 1);
  }

  scrollBy(delta: number): void {
    const pane = this.container.querySelector("iframe")?.contentDocument?.documentElement;
    if (pane) {
      pane.scrollBy({ top: delta, behavior: "auto" });
      return;
    }
    this.container.scrollBy({ top: delta, behavior: "auto" });
  }

  scrollToTop(): void {
    this.scrollBy(-1_000_000);
  }

  scrollToBottom(): void {
    this.scrollBy(1_000_000);
  }

  currentChapter(): ChapterMeta | null {
    return this.chapters[this.chapterIndex] ?? null;
  }

  currentIndex(): number {
    return this.chapterIndex;
  }

  destroy(): void {
    this.rendition?.destroy();
    this.book?.destroy();
    this.rendition = null;
    this.book = null;
    this.container.innerHTML = "";
  }
}
