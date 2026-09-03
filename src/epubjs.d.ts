declare module "epubjs" {
  /** Subset of epub.js's RenditionOptions this app passes. */
  export interface RenditionOptions {
    width?: number | string;
    height?: number | string;
    flow?: string;
    spread?: string;
    /** epub.js >= 0.3.89 sandboxes section iframes without this, which
     * kills every in-book link. */
    allowScriptedContent?: boolean;
    allowPopups?: boolean;
  }

  /** A rendered section's document (subset used by the reader). */
  export interface Contents {
    document: Document;
  }

  export interface Rendition {
    display(target?: string): Promise<void>;
    destroy(): void;
    on(event: "relocated", callback: (value: { start: { cfi: string; href?: string } }) => void): void;
    on(event: "keydown", callback: (event: KeyboardEvent) => void): void;
    on(
      event: "rendered",
      callback: (section: { href?: string }, view: { contents?: Contents }) => void,
    ): void;
    off(event: "keydown", callback: (event: KeyboardEvent) => void): void;
    hooks: {
      content: { register(fn: (contents: Contents) => void): void };
    };
  }

  export interface Book {
    ready: Promise<void>;
    renderTo(element: HTMLElement, options: RenditionOptions): Rendition;
    destroy(): void;
  }

  export default function ePub(url: ArrayBuffer): Book;
}
