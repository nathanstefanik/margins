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

  readerRendition.on("keydown", readerForwardKey);
  document.addEventListener("keydown", readerForwardKey);

  await readerRendition.display(readerStartHref || undefined);
}

const readerForwardableKeys = new Set([
  "j", "k", "g", "G", "n", "p", "i", "/", "l", "o",
  "Enter", "Escape", " ", "ArrowRight", "ArrowLeft", "PageDown", "PageUp",
]);

function readerForwardKey(event) {
  // Keys typed into form fields stay native; only the vim-style set is
  // forwarded (and preventDefault-ed so the webview doesn't double-handle).
  const tag = event.target && event.target.tagName
    ? String(event.target.tagName).toUpperCase()
    : "";
  if (tag === "INPUT" || tag === "TEXTAREA") {
    return;
  }
  if (!readerForwardableKeys.has(event.key)) {
    return;
  }
  event.preventDefault();
  window.webkit?.messageHandlers?.readerKeys?.postMessage({
    key: event.key,
    ctrl: event.ctrlKey,
    meta: event.metaKey,
    shift: event.shiftKey,
  });
}

function readerDisplay(href) {
  if (!readerRendition || !href) {
    return;
  }
  readerRendition.display(href).catch((error) => {
    readerShowError(error);
  });
}

function readerShowError(message) {
  const note = document.createElement("pre");
  note.className = "reader-error";
  note.textContent = `Reader failed: ${message}`;
  document.body.replaceChildren(note);
}

function readerScrollBy(delta) {
  if (!readerRendition) {
    return;
  }
  // Paginated flow has no vertical overflow: j/k step between pages.
  if (delta > 0) {
    readerRendition.next().catch(readerShowError);
  } else if (delta < 0) {
    readerRendition.prev().catch(readerShowError);
  }
}

function readerScrollTop() {
  if (!readerRendition) {
    return;
  }
  const location = readerRendition.currentLocation();
  if (location && location.start && location.start.href) {
    readerRendition.display(location.start.href).catch(readerShowError);
  }
}

function readerScrollBottom() {
  if (!readerRendition) {
    return;
  }
  const location = readerRendition.currentLocation();
  if (location && location.end && location.end.cfi) {
    readerRendition.display(location.end.cfi).catch(readerShowError);
  }
}

window.readerOpen = readerOpen;
window.readerDisplay = readerDisplay;
window.readerScrollBy = readerScrollBy;
window.readerScrollTop = readerScrollTop;
window.readerScrollBottom = readerScrollBottom;

readerOpen().catch((error) => {
  readerShowError(error);
});
