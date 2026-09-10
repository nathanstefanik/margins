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
// Latest typography spec from the shell: {fontSize, unit, lineHeight,
// lineWidthCh}. fontSize is a number in `unit` ("%" for macOS, "px" for
// the iOS ladder) and lands on html with !important; body text is forced
// to inherit it, because publisher sheets pin `p { font-size: ... }` and
// would otherwise ignore the root size entirely.
let readerTypography = null;
// True once the first display finished; relayouts are only queued after that.
let readerOpened = false;
let readerRelayoutTimer = null;
// Bumped by every navigation; a re-anchor pass abandons itself when a newer
// jump started while it waited for layout.
let readerNavigationToken = 0;
// The last target displayed, so `gg` can return to the chapter's anchor
// rather than the top of the file it happens to share.
let readerCurrentTarget = null;
// The most recent text selection (capture UIs consume and clear it).
let readerLastSelection = null;

function readerPost(payload) {
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.reader;
  if (handler) {
    handler.postMessage(payload);
  }
}

async function readerOpen() {
  if (!readerBookId) {
    throw new Error("missing ?book= parameter");
  }
  console.log("readerOpen: fetching book.epub");
  const response = await fetch(`book.epub?book=${encodeURIComponent(readerBookId)}`);
  if (!response.ok) {
    throw new Error(`book.epub fetch failed with ${response.status}`);
  }
  const bytes = await response.arrayBuffer();
  console.log(`readerOpen: fetched ${bytes.byteLength} bytes`);

  readerBook = ePub(bytes);
  await readerBook.ready;
  console.log("readerOpen: book ready");

  console.log("readerOpen: creating rendition");
  readerRendition = readerBook.renderTo("viewer", {
    width: "100%",
    height: "100%",
    flow: "paginated",
    spread: "none",
    // epub.js >= 0.3.89 sandboxes section iframes without these. allow-scripts
    // is what lets the internal-link onclick handlers epub.js installs fire;
    // allow-popups lets target="_blank" reach the WKUIDelegate, which opens
    // external URLs in the system browser.
    allowScriptedContent: true,
    allowPopups: true,
  });
  // Lifecycle diagnostics: epub.js's display promise can stall silently
  // when a section view never finishes; these mark where it stops.
  readerRendition.on("started", () => console.log("rendition: started"));
  readerRendition.on("attached", () => console.log("rendition: attached"));

  readerRendition.hooks.content.register(readerPreserveAspectRatio);
  readerRendition.hooks.content.register(readerStyleContents);
  readerRendition.on("relocated", readerReportRelocated);
  readerRendition.on("rendered", (section, view) => {
    if (view && view.contents && view.contents.document && section && section.href) {
      readerAttachLinks(view.contents.document, section.href);
    }
  });
  // Text selection (touch or mouse): remember it so Swift can offer
  // Note/Highlight and anchor a mark; the message handler on the native
  // side ignores this on platforms without capture UI.
  readerRendition.on("selected", (cfiRange, contents) => {
    try {
      const text = contents && contents.window
        ? String(contents.window.getSelection())
        : "";
      readerLastSelection = { cfiRange: cfiRange, text: text };
      readerPost({ type: "selected", cfiRange: cfiRange, text: text });
    } catch (error) {
      readerLastSelection = null;
    }
  });
  // Preferences may have arrived before the book finished opening.
  readerApplyViewerWidth();
  console.log("readerOpen: rendition created, displaying");

  try {
    if (readerStartCfi) {
      console.log("readerOpen: displaying start CFI");
      await readerRendition.display(readerStartCfi);
    } else {
      await readerDisplayTarget(readerStartHref || undefined);
    }
  } catch (error) {
    // A stale CFI (externally updated EPUB, position synced from another
    // machine) must not brick the reader: fall back to the chapter start.
    if (readerStartCfi) {
      await readerDisplayTarget(readerStartHref || undefined);
    } else {
      throw error;
    }
  }
  readerOpened = true;
  console.log("readerOpen: displayed, rendition live");
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
// page, then style each section's content document. The size goes on html
// (so `rem`-based publisher styles scale) and the flow containers are
// forced to inherit it — epub.js's own theme overrides cannot do this job:
// their Contents#css writes inline styles on body without !important,
// which the inherit rule would cancel. The `!important` here sits in the
// same layer epub.js itself uses for layout, so nothing accumulates.
function readerApplyTypography(fontSize, lineHeight, lineWidthCh, unit) {
  readerTypography = {
    fontSize: fontSize,
    unit: unit || "%",
    lineHeight: lineHeight,
    lineWidthCh: lineWidthCh,
  };
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
  // Measure is independent of font size: a ch is relative to the rendered
  // glyphs already, so scaling the column by the size used to turn size
  // steps into measure changes instead of bigger type.
  const width = readerTypography.lineWidthCh;
  if (width > 0) {
    viewer.style.maxWidth = `${width}ch`;
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
  // Root size on html; body and the common flow containers forced to
  // inherit it, so publisher rules like `p { font-size: 14px }` cannot
  // pin glyphs and ignore the preference.
  contents.addStylesheetRules({
    html: {
      "font-size": `${readerTypography.fontSize}${readerTypography.unit} !important`,
    },
    "body, p, li, div": {
      "font-size": "inherit !important",
    },
    body: {
      "line-height": `${readerTypography.lineHeight} !important`,
    },
  });
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

// Internal links (TOC pages, cross-references): the shell passes
// allowScriptedContent so epub.js's own link handlers can run, but its
// resolution chain (book.path.relative against the package directory)
// lands on the wrong spine href for byte-rendered books, so these
// capture-phase listeners take precedence: anchors are resolved against
// the current section per RFC 3986 and displayed directly. External
// links are left alone — allowPopups routes target="_blank" through the
// WKUIDelegate to the system browser. A dead link must not break the
// reader, so display failures are swallowed instead of raising the
// error page.
function readerAttachLinks(doc, sectionHref) {
  doc.addEventListener(
    "click",
    (event) => {
      const target = event.target;
      const anchor = target && target.closest ? target.closest("a[href]") : null;
      if (!anchor) {
        return;
      }
      const href = anchor.getAttribute("href");
      if (!href || /^(https?:|mailto:)/i.test(href)) {
        return;
      }
      event.preventDefault();
      event.stopPropagation();
      const resolved = readerResolveHref(sectionHref, href);
      if (resolved) {
        readerDisplayTarget(resolved).catch(() => {});
      }
    },
    true,
  );
}

// RFC 3986 relative resolution over the spine's paths: returns the
// book-root-relative target (with fragment, if any) for rendition.display.
function readerResolveHref(sectionHref, linkHref) {
  const hashAt = linkHref.indexOf("#");
  const path = hashAt === -1 ? linkHref : linkHref.slice(0, hashAt);
  const fragment = hashAt === -1 ? null : linkHref.slice(hashAt + 1);
  if (!path) {
    return fragment ? `${sectionHref}#${fragment}` : null;
  }
  let stack;
  if (path.charAt(0) === "/") {
    stack = [];
  } else {
    stack = sectionHref.split("/").slice(0, -1);
  }
  path.split("/").forEach((part) => {
    if (!part || part === ".") {
      return;
    }
    if (part === "..") {
      stack.pop();
    } else {
      stack.push(part);
    }
  });
  const resolved = stack.join("/");
  return fragment ? `${resolved}#${fragment}` : resolved;
}

// Chapter jumps from the shell. `href` may carry the chapter's TOC anchor
// (`path#fragment`), which is what makes a jump land on the chapter heading
// rather than the top of a file holding several chapters.
function readerDisplay(href) {
  if (!href) {
    return;
  }
  readerDisplayTarget(href).catch((error) => {
    readerShowError(error);
  });
}

// The single navigation path: displays a target and, when it carries a
// fragment, re-anchors once after the layout settles.
//
// epub.js picks the landing page from the anchor's offset at display time
// (`locationOf` then `moveTo`, which floors that offset onto a column).
// Anything that shifts layout afterwards — late image loads, web fonts, the
// readerStyleContents/readerPreserveAspectRatio hooks, the viewer's
// max-width — moves the anchor into a different column, so the jump lands a
// page or two off. Re-issuing the same display once the layout stops moving
// re-runs that same page math against settled offsets. Exactly one retry,
// never a loop.
// Resolves a chapter jump target against the spine. epub.js's
// `spineByHref` is keyed by the *manifest-relative* href (e.g.
// "wrap0000.html"), while the core's jump targets are *zip-root-relative*
// ("OEBPS/wrap0000.html") — the two only agree when the OPF sits at the
// zip root. Strip leading path segments until the spine matches, keeping
// any "#fragment"; returns the original target when nothing matches so
// epub.js's own error path stays authoritative.
function readerResolveSpineTarget(target) {
  if (!target || !readerBook || !readerBook.spine) {
    return target || undefined;
  }
  const hashAt = target.indexOf("#");
  const base = hashAt === -1 ? target : target.slice(0, hashAt);
  const fragment = hashAt === -1 ? "" : target.slice(hashAt);
  const segments = base.split("/");
  for (let strip = 0; strip < segments.length; strip++) {
    const candidate = segments.slice(strip).join("/") + fragment;
    if (readerBook.spine.get(candidate)) {
      return candidate;
    }
  }
  return target;
}

async function readerDisplayTarget(target) {
  if (!readerRendition) {
    return;
  }
  const rendition = readerRendition;
  const token = ++readerNavigationToken;
  readerCurrentTarget = target || null;
  // No target at all still means "open the book": epub.js starts at the
  // first section.
  const displayed = rendition.display(readerResolveSpineTarget(target));
  setTimeout(() => console.log("readerOpen: display still pending after 6s"), 6000);
  await displayed;
  console.log("readerOpen: display resolved for", target || "chapter start");

  const hashAt = target ? target.indexOf("#") : -1;
  if (hashAt === -1) {
    return;
  }
  const fragment = target.slice(hashAt + 1);

  try {
    const contents = (rendition.getContents() || []).filter(
      (candidate) => candidate && candidate.document && candidate.document.getElementById(fragment),
    )[0];
    if (!contents) {
      return;
    }
    const landed = readerStartCfiOf(rendition);

    await readerSettleLayout(contents.document);

    // Abandon quietly if the session moved on: a newer jump, a replaced
    // rendition, or the reader paged elsewhere while we waited.
    if (token !== readerNavigationToken || readerRendition !== rendition) {
      return;
    }
    if (landed && readerStartCfiOf(rendition) !== landed) {
      return;
    }
    if (!contents.document.getElementById(fragment)) {
      return;
    }
    await rendition.display(target);
  } catch (error) {
    // A dead anchor must not break the reading session.
  }
}

function readerStartCfiOf(rendition) {
  const location = rendition.currentLocation();
  return location && location.start ? location.start.cfi : null;
}

// Waits for what still moves a section's layout after it first renders —
// web fonts and images that arrive without intrinsic sizes — so an anchor's
// offset can be trusted. Capped, because a section that never settles must
// not hang navigation.
const READER_LAYOUT_SETTLE_CAP_MS = 300;

async function readerSettleLayout(doc) {
  const capped = new Promise((resolve) => setTimeout(resolve, READER_LAYOUT_SETTLE_CAP_MS));
  const fonts = doc.fonts ? doc.fonts.ready.then(() => {}, () => {}) : Promise.resolve();
  const images = Array.prototype.slice
    .call(doc.images || [])
    .filter((image) => !image.complete)
    .map(
      (image) =>
        new Promise((resolve) => {
          image.addEventListener("load", () => resolve(), { once: true });
          image.addEventListener("error", () => resolve(), { once: true });
        }),
    );
  await Promise.race([Promise.all([fonts].concat(images)), capped]);
  await readerNextFrame(doc);
  await readerNextFrame(doc);
}

function readerNextFrame(doc) {
  const view = doc.defaultView || window;
  return new Promise((resolve) => view.requestAnimationFrame(() => resolve()));
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

// `gg`: the start of the chapter being read. When the current chapter began
// at a TOC anchor inside this file, that anchor is the start — the top of
// the file belongs to whichever chapter came first in it.
function readerScrollTop() {
  if (!readerRendition) {
    return;
  }
  const location = readerRendition.currentLocation();
  const href = location && location.start ? location.start.href : null;
  if (!href) {
    return;
  }
  const target =
    readerCurrentTarget && readerCurrentTarget.split("#")[0] === href ? readerCurrentTarget : href;
  readerDisplayTarget(target).catch(readerShowError);
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
window.readerRelayout = readerQueueRelayout;
// Capture support (see readerResolveSpineTarget note): highlight a mark's
// CFI range (epub.js dedupes by range), collapse the active selection, and
// hand back the current page's CFI for page-anchored marks.
window.readerHighlight = function (cfiRange) {
  if (!readerRendition || !cfiRange) {
    return;
  }
  try {
    readerRendition.annotations.add("highlight", cfiRange, {}, () => {});
  } catch (error) {
    console.error("readerHighlight failed:", error);
  }
};
window.readerClearSelection = function () {
  try {
    const selection = window.getSelection();
    if (selection) {
      selection.removeAllRanges();
    }
    if (readerRendition) {
      readerRendition.getContents().forEach((contents) => {
        const selection = contents.window.getSelection();
        if (selection) {
          selection.removeAllRanges();
        }
      });
    }
  } catch (error) {
    // A stale selection is nothing to fail over.
  }
  readerLastSelection = null;
};
window.readerCurrentCfi = function () {
  const location = readerRendition ? readerRendition.currentLocation() : null;
  return location && location.start ? location.start.cfi : null;
};

readerOpen().catch((error) => {
  var detail;
  try {
    detail = JSON.stringify({
      type: typeof error,
      name: error && error.name,
      message: error && error.message,
      text: String(error),
      target: readerCurrentTarget,
    });
  } catch (e) {
    detail = String(error);
  }
  console.error("readerOpen failed:", detail);
  readerShowError(error);
});
