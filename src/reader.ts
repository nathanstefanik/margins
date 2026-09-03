import ePub, { Book, Rendition } from "epubjs";
import type { Contents } from "epubjs";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { ChapterMeta } from "./api";

export class EpubReader {
  private book: Book | null = null;
  private rendition: Rendition | null = null;
  private chapters: ChapterMeta[] = [];
  private chapterIndex = 0;

  constructor(
    private container: HTMLElement,
    private onChapterChange: (chapter: ChapterMeta, cfi?: string) => void,
    private onKeyDown: (event: KeyboardEvent) => void,
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
      // epub.js >= 0.3.89 sandboxes section iframes without this, which
      // kills every in-book link (the onclick handlers it installs never
      // fire). Popups stay blocked: external links are intercepted below
      // and opened through the opener plugin instead.
      allowScriptedContent: true,
    });
    this.rendition.on("keydown", this.onKeyDown);

    this.rendition.on("relocated", (location: { start: { cfi: string; href?: string } }) => {
      const start = location.start;
      // Follow the renderer whenever it moves between sections — paging
      // across a chapter boundary or an in-book link — by matching the
      // spine href instead of trusting the stored index.
      const matched = start.href ? this.indexOfHref(start.href) : -1;
      if (matched >= 0) {
        this.chapterIndex = matched;
      }
      const current = this.chapters[this.chapterIndex];
      if (current) {
        this.onChapterChange(current, start.cfi);
      }
    });
    // In-book links (TOC pages, cross-references): epub.js's own handler
    // resolves relative hrefs against the package path, which lands on
    // the wrong spine href for byte-rendered books, so intercept anchors
    // and display the section ourselves. Capture phase beats epub.js's
    // rewritten onclick.
    this.rendition.on("rendered", (section, view) => {
      const doc = view?.contents?.document;
      if (doc && section?.href) {
        this.attachLinkHandler(doc, section.href);
      }
    });

    // External links: sandboxed-iframe popups are unreliable under wry, so
    // intercept them and open through the opener plugin. The classifier
    // deliberately mirrors epub.js's own external-link test (`://`) so the
    // two can't disagree. Internal links never reach this hook's handlers:
    // the capture listener above stops them first.
    this.rendition.hooks.content.register((contents: Contents) => {
      contents.document.querySelectorAll("a[href]").forEach((anchor) => {
        const href = anchor.getAttribute("href") ?? "";
        if (!(href.includes("://") || href.startsWith("mailto:"))) return;
        anchor.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          openUrl(href).catch((error) => console.error("open external link", error));
        });
      });
    });

    if (chapters[startIndex]) {
      await this.displayChapter(startIndex);
    } else if (chapters[0]) {
      await this.displayChapter(0);
    }
  }

  /// Intercepts clicks on internal anchors in one section's document:
  /// external links keep their default handling, internal ones navigate
  /// through the rendition (a plain navigation would fail to resolve).
  private attachLinkHandler(doc: Document, sectionHref: string): void {
    doc.addEventListener(
      "click",
      (event) => {
        const target = event.target as HTMLElement | null;
        const anchor = target?.closest?.("a[href]") as HTMLAnchorElement | null;
        if (!anchor) return;
        const href = anchor.getAttribute("href");
        if (!href || /^(https?:|mailto:)/i.test(href)) return;
        event.preventDefault();
        event.stopPropagation();
        const resolved = resolveEpubHref(sectionHref, href);
        if (resolved) {
          // A dead in-book link must not break the reading session.
          void this.rendition?.display(resolved).catch(() => {});
        }
      },
      true,
    );
  }

  /// Finds the spine index for a relocated href: fragments are stripped,
  /// then an exact match on `ChapterMeta.href` (the full in-zip path),
  /// then a suffix match so a differently-rooted href still resolves.
  private indexOfHref(href: string): number {
    const path = href.split("#")[0];
    const candidates = this.chapters.map((chapter) => chapter.href);
    const exact = candidates.findIndex((candidate) => candidate === path);
    if (exact >= 0) return exact;
    return candidates.findIndex((candidate) =>
      candidate === path || candidate.endsWith(`/${path}`) || path.endsWith(`/${candidate}`),
    );
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
    this.rendition?.off("keydown", this.onKeyDown);
    this.rendition?.destroy();
    this.book?.destroy();
    this.rendition = null;
    this.book = null;
    this.container.innerHTML = "";
  }
}

/// Resolves an anchor's href against the section it appears in, per RFC
/// 3986 relative resolution over the spine's paths. Returns the
/// book-root-relative target (with fragment, if any) for
/// `rendition.display`, or `null` when there is nothing to navigate to.
function resolveEpubHref(sectionHref: string, linkHref: string): string | null {
  const [path, fragment] = linkHref.split("#");
  if (!path) {
    return fragment ? `${sectionHref}#${fragment}` : null;
  }
  let stack: string[];
  if (path.startsWith("/")) {
    // Root-relative: resolve from the book root.
    stack = [];
  } else {
    stack = sectionHref.split("/").slice(0, -1);
  }
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") stack.pop();
    else stack.push(part);
  }
  const resolved = stack.join("/");
  return fragment ? `${resolved}#${fragment}` : resolved;
}
