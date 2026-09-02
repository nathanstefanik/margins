"use strict";

// Margins reader page: mirrors src/reader.ts from the Tauri frontend. The
// whole-book EPUB is fetched from the margins-reader:// scheme handler and
// rendered with epub.js in paginated mode. Swift drives chapter changes and
// scrolling through the window.reader* functions defined here.

const readerParams = new URLSearchParams(window.location.search);
const readerBookId = readerParams.get("book");
const readerStartHref = readerParams.get("chapter");
// Saved reading position: an epub.js CFI takes precedence over the chapter
// href so a resumed book opens on the same page.
const readerStartCfi = readerParams.get("cfi");

let readerBook = null;
let readerRendition = null;
// Latest typography spec from the shell: {fontSize, lineHeight, lineWidthCh}.
// Applied as soon as the rendition exists and to every section as it loads.
let readerTypography = null;
// True once the first display finished; relayouts are only queued after that.
let readerOpened = false;
let readerRelayoutTimer = null;

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

  readerRendition.hooks.content.register(readerPreserveAspectRatio);
  readerRendition.hooks.content.register(readerStyleContents);
  readerRendition.on("relocated", readerReportRelocated);

  // Preferences may have arrived before the book finished opening.
  readerApplyViewerWidth();

  try {
    await readerRendition.display(readerStartCfi || readerStartHref || undefined);
  } catch (error) {
    // A stale CFI (externally updated EPUB, position synced from another
    // machine) must not brick the reader: fall back to the chapter top.
    if (readerStartCfi) {
      await readerRendition.display(readerStartHref || undefined);
    } else {
      throw error;
    }
  }
  readerOpened = true;
}

// Keeps images at their intrinsic aspect ratio: the paginated columns would
// otherwise stretch content to fill the window's shape, and Gutenberg-style
// covers use SVGs with preserveAspectRatio="none".
function readerPreserveAspectRatio(contents) {
  contents.addStylesheetRules({
    "img, svg, image": {
      "max-width": "100% !important",
      "max-height": "100vh !important",
      "width": "auto !important",
      "height": "auto !important",
      "object-fit": "contain !important",
    },
  });
  contents.document
    .querySelectorAll("svg[preserveAspectRatio='none'], svg[preserveAspectRatio='None']")
    .forEach((svg) => {
      svg.setAttribute("preserveAspectRatio", "xMidYMid meet");
    });
}

// Typography (called from Swift): constrain the text column in the outer
// page, then style each section's content document. Font size goes on the
// root (so `rem`-based publisher styles scale) with the body inheriting, so
// publisher `body` font rules don't win; `!important` inline styles sit in
// the same layer epub.js itself uses for layout, so nothing accumulates.
function readerApplyTypography(fontSize, lineHeight, lineWidthCh) {
  readerTypography = { fontSize: fontSize, lineHeight: lineHeight, lineWidthCh: lineWidthCh };
  readerApplyViewerWidth();
  if (readerRendition) {
    readerRendition.getContents().forEach((contents) => readerStyleContents(contents));
    readerQueueRelayout();
  }
}

function readerApplyViewerWidth() {
  const viewer = document.getElementById("viewer");
  if (!viewer || !readerTypography) {
    return;
  }
  const width = readerTypography.lineWidthCh;
  if (width > 0) {
    // Line width is the target measure in characters per line of reading
    // text, so the column scales with font size: stepping the font size
    // widens the column rather than shrinking the measure.
    const scaled = width * (readerTypography.fontSize / 100);
    viewer.style.maxWidth = `${scaled}ch`;
    viewer.style.margin = "0 auto";
  } else {
    viewer.style.maxWidth = "none";
    viewer.style.margin = "";
  }
}

// The stage only re-lays out on window resizes (epub.js listens for those
// exclusively), so changing the inner viewer's width must force one: without
// it the columns keep the old pixel width and the next page peeks into the
// wider viewport, cut off. rendition.resize() re-measures the stage,
// recomputes the column layout, and re-displays at the current position.
function readerQueueRelayout() {
  if (!readerOpened || !readerRendition) {
    return;
  }
  if (readerRelayoutTimer) {
    clearTimeout(readerRelayoutTimer);
  }
  readerRelayoutTimer = setTimeout(() => {
    readerRelayoutTimer = null;
    if (readerRendition) {
      readerRendition.resize();
    }
  }, 120);
}

function readerStyleContents(contents) {
  if (!readerTypography || !contents || !contents.document) {
    return;
  }
  const doc = contents.document;
  if (doc.documentElement) {
    doc.documentElement.style.setProperty("font-size", `${readerTypography.fontSize}%`, "important");
  }
  const body = contents.content || doc.body;
  if (body) {
    body.style.setProperty("font-size", "inherit", "important");
    body.style.setProperty("line-height", String(readerTypography.lineHeight), "important");
  }
}

// Forward relocation to the shell: page position within the chapter for the
// progress footer, plus the section href and the exact CFI so the shell can
// follow chapter changes made by paging across boundaries and save the
// reading position.
function readerReportRelocated(location) {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reader;
  if (!handler) {
    return;
  }
  const start = location && location.start;
  const displayed = (start && start.displayed) || {};
  handler.postMessage({
    type: "relocated",
    href: start && start.href ? start.href : null,
    cfi: start && start.cfi ? start.cfi : null,
    page: displayed.page || 1,
    totalPages: displayed.total || 0,
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
window.readerApplyTypography = readerApplyTypography;

readerOpen().catch((error) => {
  readerShowError(error);
});
