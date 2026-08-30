declare module "epubjs" {
  export interface Rendition {
    display(target?: string): Promise<void>;
    destroy(): void;
    on(event: string, callback: (value: { start: { cfi: string } }) => void): void;
  }

  export interface Book {
    ready: Promise<void>;
    renderTo(element: HTMLElement, options: Record<string, unknown>): Rendition;
    destroy(): void;
  }

  export default function ePub(url: ArrayBuffer): Book;
}
