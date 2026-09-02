"use strict";

// Margins reader page: mirrors src/reader.ts from the Tauri frontend. The
// whole-book EPUB is fetched from the margins-reader:// scheme handler and
// rendered with epub.js in paginated mode. Swift drives chapter changes and
// scrolling through the window.reader* functions defined here.

const readerParams = new URLSearchParams(window.location.search);
const readerBookId = readerParams.get("book");
const readerStartHref = readerParams.get("chapter");

let readerBook = null;
let readerRendition = null;

async function readerOpen() {
  if (!readerBookId) {
    throw new Error("missing ?book= parameter");
  }
  const response = await fetch(`book.epub?book=${encodeURIComponent(readerBookId)}`);
  if (!response.ok) {
    throw new Error(`book.epub fetch failed with ${response.status}`);
  }
  const bytes = await response.arrayBuffer();

  readerBook = ePub(bytes);
  await readerBook.ready;

  readerRendition = readerBook.renderTo("viewer", {
    width: "100%",
    height: "100%",
    flow: "paginated",
    spread: "none",
  });

  await readerRendition.display(readerStartHref || undefined);
}

function readerDisplay(href) {
  if (readerRendition && href) {
    void readerRendition.display(href);
  }
}

function readerScrollBy(delta) {
  const pane = document.querySelector("iframe")?.contentDocument?.documentElement;
  if (pane) {
    pane.scrollBy({ top: delta, behavior: "auto" });
    return;
  }
  document.getElementById("viewer")?.scrollBy({ top: delta, behavior: "auto" });
}

function readerScrollTop() {
  readerScrollBy(-1000000);
}

function readerScrollBottom() {
  readerScrollBy(1000000);
}

window.readerOpen = readerOpen;
window.readerDisplay = readerDisplay;
window.readerScrollBy = readerScrollBy;
window.readerScrollTop = readerScrollTop;
window.readerScrollBottom = readerScrollBottom;

readerOpen().catch((error) => {
  const note = document.createElement("pre");
  note.className = "reader-error";
  note.textContent = `Reader failed: ${error}`;
  document.body.replaceChildren(note);
});
