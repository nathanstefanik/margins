"use strict";

// Margins reader page. The whole-book EPUB is fetched from the
// margins-reader:// scheme handler and rendered with epub.js in paginated
// mode. Swift drives chapter changes and scrolling through the
// window.reader* functions defined here.

const readerParams = new URLSearchParams(window.location.search);
const readerBookId = readerParams.get("book");
const readerStartHref = readerParams.get("chapter");
// Saved reading position: an epub.js CFI takes precedence over the chapter
// href so a resumed book opens on the same page.
const readerStartCfi = readerParams.get("cfi");
// Desktop (macOS) opt-in: the URL carries platform=macos, which enables the
// width-aware one/two-page policy below. iOS omits it and keeps the
// original full-width single-column behavior.
const readerIsDesktop = readerParams.get("platform") === "macos";

let readerBook = null;
let readerRendition = null;
// Latest typography spec from the shell: {fontSize, unit, lineHeight,
// lineWidthCh}. fontSize is a number in `unit` ("%" for macOS, "px" for
// the iOS ladder) and lands on html with !important; body text is forced
// to inherit it, because publisher sheets pin `p { font-size: ... }` and
// would otherwise ignore the root size entirely.
let readerTypography = null;
// Chosen typeface key ("serif" | "sans" on iOS), resolved in the webview
// to the system's New York / SF Pro — nothing is bundled. null (macOS)
// leaves publisher fonts alone.
let readerFontFace = null;

const READER_FONT_FACES = {
  serif: "ui-serif, Georgia, serif",
  sans: "-apple-system, 'Helvetica Neue', sans-serif",
};
// Reading-surface palettes, mirrored by the native chrome (Paper.swift /
// DesignTokens.swift) and reader.html's pre-paint styles. Keep in sync.
const READER_THEMES = {
  light: { background: "#f4f1ea", ink: "#111111", scheme: "light" },
  dark: { background: "#1b1a18", ink: "#e6e2da", scheme: "dark" },
};
// The current surface theme; the URL carries the initial choice so the
// class set in reader.html matches until Swift calls readerSetTheme.
let readerTheme = readerParams.get("theme") === "dark" ? "dark" : "light";
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

// MARK: Desktop page layout (macOS)
//
// One policy, measured from the actual reading viewport (the uncapped
// #page container, after native sidebar/notes allocation) and the book's
// rendered body font. See docs/testing/macos-reader-layout.md for the
// engine contract these calls rely on.
const READER_DESKTOP_INSET_X = 24;
const READER_DESKTOP_INSET_Y = 24;
// Below this viewport width the outer insets shrink before content clips.
const READER_DESKTOP_NARROW_WIDTH = 320;
const READER_DESKTOP_NARROW_INSET_X = 8;
// Whitespace between the two pages; epub.js takes it as the layout gap.
const READER_DESKTOP_GUTTER = 40;
// Automatic enters two pages this far above the fit threshold and leaves
// below the threshold, so dragging a divider cannot flip repeatedly.
const READER_LAYOUT_HYSTERESIS = 32;
// Automatic needs a comfortable measure per page; manual Two Pages accepts
// a tighter one before falling back to a single column.
const READER_AUTOMATIC_MAX_MEASURE_CH = 56;
const READER_DOUBLE_MIN_MEASURE_CH = 40;
// Used only before any section has rendered: half the requested em,
// a typical digit width for a text face.
const READER_FALLBACK_GLYPH_EM = 0.5;

// The requested mode: "automatic" | "single" | "double". Stored as it
// arrives so a call before the book opens is honored when it does.
let readerRequestedLayout = "automatic";
// The last geometry actually written to the page, so identical updates are
// skipped (a state change here can otherwise feed the ResizeObserver).
let readerAppliedLayout = null;
// Pages reported by the last resolution; Automatic's hysteresis input.
let readerPreviousPages = 1;
// Cached body-font digit width; keyed by the typography/face revision.
let readerGlyphCache = null;
let readerViewportObserver = null;
let readerLayoutUpdateTimer = null;
let readerLayoutFrame = null;
// Bumped whenever typography or the typeface changes, so the glyph cache
// invalidates without re-measuring on every relayout.
let readerTypographyRevision = 0;

// MARK: Reflow transactions
//
// A layout change (viewport, typography, page mode) repaginates the book.
// The engine re-displays at its own idea of the current location, which can
// drift a page after reflow, and it emits provisional relocations while
// doing so. A transaction captures the settled page start, resizes, waits
// for the engine's queue to drain, and re-anchors to the captured CFI —
// but only while no newer navigation or layout superseded it.
//
// The last settled page start, captured before a reflow so the anchor is
// the reader's real position, never a provisional mid-relayout location.
let readerSettledCfi = null;
// Bumped every time a transaction is scheduled; a transaction whose
// generation changed abandons itself.
let readerLayoutGeneration = 0;
// Set while a transaction is between its resize and its re-anchor. While
// set, relocation reports are withheld from the shell: they describe a
// half-relaid-out book.
let readerLayoutInFlight = null;
// Bounded wait for the rendition queue to drain after a resize.
const READER_REFLOW_SETTLE_CAP_MS = 500;

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
    // Desktop gutter: whitespace between the two pages (epub.js otherwise
    // derives its own even(floor(width/12)) gutter). iOS leaves it unset.
    gap: readerIsDesktop ? READER_DESKTOP_GUTTER : undefined,
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
  readerRendition.on("rendered", (section, view) => {
    if (view && view.contents && view.contents.document && section && section.href) {
      // Tap zones before the link handler: both are capture-phase, and the
      // zone logic must see every click (link taps page AND navigate).
      readerAttachTapZone(view.contents.document);
      readerAttachLinks(view.contents.document, section.href);
    }
    if (readerIsDesktop && view && view.contents && view.contents.document) {
      // The body font is only real once a section rendered: re-measure the
      // digit width and re-resolve, then again once webfonts settle.
      readerQueueLayoutUpdate();
      const doc = view.contents.document;
      if (doc.fonts && doc.fonts.ready) {
        doc.fonts.ready.then(() => readerQueueLayoutUpdate(), () => {});
      }
    }
    try {
      readerReportRelocated(readerRendition.currentLocation());
    } catch (error) {}
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
  // Page counts for the running footer: epub.js emits `relocated` with
  // start.displayed.{page,total}. The reporter existed but was never
  // attached, so the shell's progress stayed nil.
  readerRendition.on("relocated", readerReportRelocated);
  if (readerIsDesktop) {
    readerInstallViewportObserver();
  }
  // Preferences and the page-layout mode may have arrived before the book
  // finished opening; this applies the stored state to the fresh rendition.
  readerApplyPageLayout();
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
  // The effective layout is only real now; report it so the shell can
  // describe one-page fallbacks (and clear the "loading" state).
  readerReportLayoutChanged();
  // First paint can beat the relocated listener; report whatever mapping
  // is already known so the footer is not blank until the next turn.
  try {
    readerReportRelocated(readerRendition.currentLocation());
  } catch (error) {}
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
  if (readerRendition) {
    // Restyle before measuring: the glyph width must be read from the
    // section font this call just selected.
    readerRendition.getContents().forEach((contents) => readerStyleContents(contents));
  }
  readerTypographyRevision += 1;
  readerApplyPageLayout();
  if (readerRendition) {
    readerQueueRelayout();
  }
}

/// The iOS path, unchanged: the measure is expressed in the *outer*
/// document's `ch`, and 0 disables the cap (full-width text).
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

// pure policy: given the available reading width, the body font's digit
// width, the selected per-page measure, and the previously rendered page
// count, decide how many pages fit and how wide the viewer may be.
//
// Two pages fit when the whole spread — outer insets, the inter-page
// gutter, and two pages of `measure` characters — is no wider than the
// viewport. The viewer is capped at the publisher-like single-page or
// two-page measure so a very wide window keeps comfortable margins.
function readerResolveLayout(options) {
  const opts = options || {};
  const mode = opts.mode === "single" || opts.mode === "double" ? opts.mode : "automatic";
  const widthPx = Math.max(0, Number(opts.widthPx) || 0);
  const glyphWidthPx = Number(opts.glyphWidthPx) > 0
    ? Number(opts.glyphWidthPx)
    : READER_FALLBACK_GLYPH_EM * 16;
  const lineWidthCh = Number(opts.lineWidthCh) > 0 ? Number(opts.lineWidthCh) : 72;
  const previousPages = opts.previousPages === 2 ? 2 : 1;

  const insetsPx = READER_DESKTOP_INSET_X * 2;
  const singleCapPx = insetsPx + lineWidthCh * glyphWidthPx;
  const doubleCapPx = insetsPx + READER_DESKTOP_GUTTER + 2 * lineWidthCh * glyphWidthPx;

  if (mode === "single") {
    return { pages: 1, viewerWidthPx: Math.min(widthPx, singleCapPx) };
  }

  const minMeasureCh = mode === "double"
    ? READER_DOUBLE_MIN_MEASURE_CH
    : Math.min(lineWidthCh, READER_AUTOMATIC_MAX_MEASURE_CH);
  const fitWidthPx = insetsPx + READER_DESKTOP_GUTTER + 2 * minMeasureCh * glyphWidthPx;
  // Automatic's hysteresis: enter two-page 32 CSS px above the fit
  // threshold, leave below it. Manual Two Pages uses the threshold
  // directly.
  const thresholdPx = mode === "double" || previousPages === 2
    ? fitWidthPx
    : fitWidthPx + READER_LAYOUT_HYSTERESIS;
  const pages = widthPx >= thresholdPx ? 2 : 1;
  const capPx = pages === 2 ? doubleCapPx : singleCapPx;
  return { pages: pages, viewerWidthPx: Math.min(widthPx, capPx) };
}

// Applies the resolved layout to the outer page and the rendition. macOS
// only; iOS keeps readerApplyViewerWidth's original behavior.
function readerApplyPageLayout() {
  if (!readerIsDesktop) {
    readerApplyViewerWidth();
    return false;
  }
  const page = document.getElementById("page");
  const viewer = document.getElementById("viewer");
  if (!page || !viewer) {
    return false;
  }
  const availableWidth = page.clientWidth;
  if (!(availableWidth > 0)) {
    return false;
  }
  const lineWidthCh = readerTypography && readerTypography.lineWidthCh > 0
    ? readerTypography.lineWidthCh
    : 0;
  const mode = readerEffectiveLayoutMode();
  const resolved = readerResolveLayout({
    mode: mode,
    widthPx: availableWidth,
    glyphWidthPx: readerBodyGlyphWidth(),
    lineWidthCh: lineWidthCh,
    previousPages: readerPreviousPages,
  });
  const insetX = availableWidth < READER_DESKTOP_NARROW_WIDTH
    ? READER_DESKTOP_NARROW_INSET_X
    : READER_DESKTOP_INSET_X;
  const geometry = {
    mode: mode,
    pages: resolved.pages,
    viewerWidthPx: Math.max(0, Math.round(resolved.viewerWidthPx)),
    insetX: insetX,
  };
  if (readerAppliedLayout &&
      readerAppliedLayout.pages === geometry.pages &&
      readerAppliedLayout.viewerWidthPx === geometry.viewerWidthPx &&
      readerAppliedLayout.insetX === geometry.insetX &&
      readerAppliedLayout.mode === geometry.mode) {
    return false;
  }
  readerAppliedLayout = geometry;
  readerPreviousPages = resolved.pages;
  readerReportLayoutChanged();

  viewer.style.boxSizing = "border-box";
  viewer.style.width = "100%";
  viewer.style.maxWidth = `${geometry.viewerWidthPx}px`;
  viewer.style.margin = "0 auto";
  viewer.style.padding = `${READER_DESKTOP_INSET_Y}px ${insetX}px`;

  if (readerRendition) {
    readerApplyRenditionSpread();
    readerQueueRelayout();
  }
  return true;
}

// Navigation starts a new layout epoch: a transaction scheduled against
// the old one must not run and re-anchor to the pre-navigation page. The
// settled anchor is dropped too — it describes the page the reader just
// left, and a transaction scheduled around the navigation must fall back
// to the engine's live location instead.
function readerInvalidatePendingLayout() {
  readerLayoutGeneration += 1;
  readerSettledCfi = null;
}

// Navigations currently awaiting their display. Relocations that resolve
// one are trusted even while layout work is queued: they are the user's
// destination, not a provisional re-layout landing.
let readerPendingNavigations = 0;

function readerBeginNavigation() {
  readerPendingNavigations += 1;
}

function readerEndNavigation() {
  readerPendingNavigations = Math.max(0, readerPendingNavigations - 1);
}

// True while the geometry is known to be mid-change: a re-resolution or
// engine resize is queued, or a transaction is running. Relocations
// emitted during this window describe a half-relaid-out book and must not
// become the reflow anchor.
function readerLayoutWorkPending() {
  return !!(
    readerLayoutInFlight ||
    readerRelayoutTimer !== null ||
    readerLayoutUpdateTimer !== null ||
    readerLayoutFrame !== null
  );
}

// Keeps the rendition's column count in step with the resolved policy:
// "auto" with the fit threshold lets epub.js split into two columns only
// when the stage is wide enough; "none" pins a single column.
function readerApplyRenditionSpread() {
  if (!readerRendition || !readerAppliedLayout) {
    return;
  }
  if (readerAppliedLayout.pages === 2) {
    const measureCh = readerAppliedLayout.mode === "double"
      ? READER_DOUBLE_MIN_MEASURE_CH
      : Math.min(
          readerTypography && readerTypography.lineWidthCh > 0 ? readerTypography.lineWidthCh : 72,
          READER_AUTOMATIC_MAX_MEASURE_CH,
        );
    readerRendition.spread("auto", READER_DESKTOP_GUTTER + 2 * measureCh * readerBodyGlyphWidth());
  } else {
    readerRendition.spread("none");
  }
}

// Tells the shell what was requested and what is actually on screen, so
// the typography popover can explain a Two Pages fallback without
// inferring it. Only posted once the book is open: before that the count
// is not real, and the shell must not claim a fallback it cannot see.
function readerReportLayoutChanged() {
  if (!readerIsDesktop || !readerOpened || !readerAppliedLayout) {
    return;
  }
  readerPost({
    type: "layoutChanged",
    requested: readerRequestedLayout,
    pages: readerAppliedLayout.pages,
  });
}

// Covers and fixed-layout sections keep the publisher's layout; RTL and
// vertical writing stay single-page until the pinned engine's spread
// treatment is verified for them. The requested mode is still remembered
// so a fallback can be reported as a fallback.
function readerEffectiveLayoutMode() {
  if (!readerBook) {
    return readerRequestedLayout;
  }
  const metadata = readerBook.package && readerBook.package.metadata
    ? readerBook.package.metadata
    : {};
  if (metadata.layout === "pre-paginated" || metadata.direction === "rtl") {
    return "single";
  }
  if (readerRendition) {
    const contents = readerRendition.getContents() || [];
    for (let index = 0; index < contents.length; index += 1) {
      const doc = contents[index] && contents[index].document;
      if (!doc || !doc.body || !doc.defaultView) {
        continue;
      }
      const writingMode = doc.defaultView.getComputedStyle(doc.body).writingMode || "";
      if (writingMode.indexOf("vertical") === 0) {
        return "single";
      }
    }
  }
  return readerRequestedLayout;
}

// The width of one digit in the book's rendered body font. Measured from
// a live section when one exists (after typography and font face are
// applied); the outer document is only a fallback, and a half-em estimate
// covers the window before the first render.
function readerBodyGlyphWidth() {
  const key = `${readerTypographyRevision}|${readerFontFace || "publisher"}`;
  if (readerGlyphCache && readerGlyphCache.key === key && readerGlyphCache.widthPx > 0) {
    return readerGlyphCache.widthPx;
  }
  let widthPx = 0;
  if (readerRendition) {
    const contents = readerRendition.getContents() || [];
    for (let index = 0; index < contents.length; index += 1) {
      widthPx = readerMeasureGlyphInDocument(contents[index] && contents[index].document);
      if (widthPx > 0) {
        break;
      }
    }
  }
  if (!(widthPx > 0)) {
    widthPx = readerFallbackGlyphWidth();
  }
  readerGlyphCache = { key: key, widthPx: widthPx };
  return widthPx;
}

function readerFallbackGlyphWidth() {
  const typography = readerTypography;
  const px = typography
    ? (typography.unit === "px" ? typography.fontSize : (typography.fontSize / 100) * 16)
    : 16;
  return Math.max(1, px * READER_FALLBACK_GLYPH_EM);
}

// Canvas `measureText` is the only way to read the actual glyph metrics
// the browser will use; measuring "0" matches the CSS `ch` unit.
function readerMeasureGlyphInDocument(doc) {
  try {
    if (!doc || !doc.body) {
      return 0;
    }
    const canvas = doc.createElement("canvas");
    const context = canvas.getContext("2d");
    if (!context) {
      return 0;
    }
    const style = doc.defaultView.getComputedStyle(doc.body);
    context.font = `${style.fontStyle || "normal"} ${style.fontWeight || "400"} ${style.fontSize || "16px"} ${style.fontFamily || "serif"}`;
    const width = context.measureText("0").width;
    return Number.isFinite(width) && width > 0 ? width : 0;
  } catch (error) {
    return 0;
  }
}

// The stage only re-lays out on window resizes (epub.js listens for those
// exclusively), so changing the inner viewer's width must force one: without
// it the columns keep the old pixel width and the next page peeks into the
// wider viewport, cut off. On iOS a resize is all that is needed; on the
// desktop this schedules a reflow transaction that preserves the passage.
function readerQueueRelayout() {
  if (!readerOpened || !readerRendition) {
    return;
  }
  if (readerRelayoutTimer) {
    clearTimeout(readerRelayoutTimer);
  }
  if (readerIsDesktop) {
    // The anchor is read when the transaction starts, not here: the
    // debounce can span a user navigation, and anchoring to the location
    // captured before it would drag the reader back. The generation
    // captured here still lets a newer schedule or navigation cancel it.
    const rendition = readerRendition;
    const token = readerNavigationToken;
    const generation = (readerLayoutGeneration += 1);
    readerRelayoutTimer = setTimeout(() => {
      readerRelayoutTimer = null;
      readerRunLayoutTransaction(generation, token, rendition);
    }, 120);
    return;
  }
  readerRelayoutTimer = setTimeout(() => {
    readerRelayoutTimer = null;
    if (readerRendition) {
      readerRendition.resize();
    }
  }, 120);
}

// A transaction is only allowed to finish if nothing superseded it: not a
// newer layout, not a user navigation, not a different rendition.
function readerLayoutIsCurrent(generation, token, rendition) {
  return generation === readerLayoutGeneration &&
    token === readerNavigationToken &&
    rendition === readerRendition;
}

// Waits out in-flight navigations (bounded) so a reflow never interleaves
// with a display that is still resolving. Returns false if the wait timed
// out or the transaction was superseded while waiting.
async function readerAwaitIdleNavigation(generation, token, rendition) {
  const deadline = Date.now() + 2000;
  while (readerPendingNavigations > 0 && Date.now() < deadline) {
    if (!readerLayoutIsCurrent(generation, token, rendition)) {
      return false;
    }
    await new Promise((resolve) => setTimeout(resolve, 16));
  }
  return readerLayoutIsCurrent(generation, token, rendition);
}

async function readerRunLayoutTransaction(generation, token, rendition) {
  if (!(await readerAwaitIdleNavigation(generation, token, rendition))) {
    // A navigation superseded this reflow. Its own display re-measures the
    // stage, but re-apply the geometry once the dust settles so a stale
    // column step cannot survive (an in-section page turn does not
    // re-measure by itself).
    readerQueueLayoutUpdate();
    return;
  }
  // The settled anchor, read now: everything before this point is the
  // reader's real position; everything after it belongs to the new layout.
  const anchor = readerSettledCfi || readerStartCfiOf(rendition);
  console.log(`reflow: start generation=${generation} anchor=${anchor}`);
  readerLayoutInFlight = { generation: generation, token: token, anchor: anchor };
  try {
    rendition.resize();
    await readerWaitForEngineSettle(rendition);
    if (!readerLayoutIsCurrent(generation, token, rendition)) {
      console.log(`reflow: superseded generation=${generation} token=${token}`);
      return;
    }
    if (anchor) {
      await rendition.display(anchor);
    }
  } catch (error) {
    // A failed re-anchor keeps the last settled position and surfaces
    // through the console. Exactly one attempt: no retry loop.
    console.error("readerRunLayoutTransaction failed:", error);
  } finally {
    if (readerLayoutInFlight && readerLayoutInFlight.generation === generation) {
      readerLayoutInFlight = null;
    }
  }
  if (!readerLayoutIsCurrent(generation, token, rendition)) {
    return;
  }
  await readerNextFrame(document);
  readerUpdateSettledCfi();
  // Publish only the settled location; everything emitted during the
  // transaction was provisional and deliberately withheld.
  try {
    readerReportRelocated(rendition.currentLocation());
  } catch (error) {}
}

// epub.js serialises resize/display work through its rendition queue, whose
// rAF-driven drain is the engine's own settle signal. Capped, because a
// section that never finishes must not hang the reader.
async function readerWaitForEngineSettle(rendition) {
  const queue = rendition.q;
  const drained = new Promise((resolve) => {
    const check = () => {
      if (rendition !== readerRendition || !queue || (queue._q.length === 0 && !queue.running)) {
        resolve();
        return;
      }
      setTimeout(check, 16);
    };
    check();
  });
  const capped = new Promise((resolve) => setTimeout(resolve, READER_REFLOW_SETTLE_CAP_MS));
  await Promise.race([drained, capped]);
  await readerNextFrame(document);
  await readerNextFrame(document);
}

function readerUpdateSettledCfi() {
  if (readerLayoutInFlight) {
    return;
  }
  readerCaptureSettledCfi();
}

// Records the page the reader is looking at as the reflow anchor. Called
// when a navigation has finished (its display resolved), where the live
// location is authoritative even if a geometry transaction is still
// queued: the user's page is the page on screen.
function readerCaptureSettledCfi() {
  const cfi = readerRendition ? readerStartCfiOf(readerRendition) : null;
  if (cfi) {
    readerSettledCfi = cfi;
  }
}

// Page layout mode from the shell. Accepted before the book opens: the
// value is stored and applied as soon as the rendition exists. Unknown
// values fall back to Automatic.
function readerSetPageLayout(mode) {
  readerRequestedLayout = mode === "single" || mode === "double" ? mode : "automatic";
  readerQueueLayoutUpdate();
}

// Debounced layout update for events that can arrive in bursts while the
// page is still churning (a section rendering, web fonts settling).
function readerQueueLayoutUpdate() {
  if (!readerIsDesktop || !readerOpened) {
    return;
  }
  if (readerLayoutUpdateTimer) {
    clearTimeout(readerLayoutUpdateTimer);
  }
  readerLayoutUpdateTimer = setTimeout(() => {
    readerLayoutUpdateTimer = null;
    readerApplyPageLayout();
  }, 120);
}

// One resolution per animation frame for continuous viewport drags. The
// resolution itself is cheap (the glyph width is cached) and applying it
// before epub.js's own 50 ms window-resize handler keeps the engine's
// divisor in step with the policy during the drag.
function readerScheduleLayoutUpdate() {
  if (!readerIsDesktop || !readerOpened) {
    return;
  }
  if (readerLayoutFrame) {
    return;
  }
  readerLayoutFrame = requestAnimationFrame(() => {
    readerLayoutFrame = null;
    readerApplyPageLayout();
  });
}

// Observes the uncapped #page container, never the capped #viewer: an
// observer on the viewer would see its own width changes and loop.
function readerInstallViewportObserver() {
  if (readerViewportObserver || typeof ResizeObserver === "undefined") {
    return;
  }
  const page = document.getElementById("page");
  if (!page) {
    return;
  }
  readerViewportObserver = new ResizeObserver(() => readerScheduleLayoutUpdate());
  readerViewportObserver.observe(page);
  window.addEventListener("unload", readerTeardownViewportObserver);
  window.addEventListener("pagehide", readerTeardownViewportObserver);
}

function readerTeardownViewportObserver() {
  if (readerViewportObserver) {
    readerViewportObserver.disconnect();
    readerViewportObserver = null;
  }
  if (readerLayoutUpdateTimer) {
    clearTimeout(readerLayoutUpdateTimer);
    readerLayoutUpdateTimer = null;
  }
  if (readerLayoutFrame) {
    cancelAnimationFrame(readerLayoutFrame);
    readerLayoutFrame = null;
  }
  if (readerRelayoutTimer) {
    clearTimeout(readerRelayoutTimer);
    readerRelayoutTimer = null;
  }
  // Invalidate any transaction still waiting: the page is going away.
  readerLayoutGeneration += 1;
  readerLayoutInFlight = null;
  window.removeEventListener("unload", readerTeardownViewportObserver);
  window.removeEventListener("pagehide", readerTeardownViewportObserver);
}

// Theme (called from Swift): swap the surface palette at runtime. The
// outer page and every section document take the themed background and
// ink; readerStyleContents forces publisher ink onto the palette.
function readerApplyTheme(theme) {
  readerTheme = Object.prototype.hasOwnProperty.call(READER_THEMES, theme) ? theme : "light";
  const palette = READER_THEMES[readerTheme];
  document.documentElement.classList.toggle("reader-dark", readerTheme === "dark");
  document.documentElement.style.colorScheme = palette.scheme;
  if (readerRendition) {
    readerRendition.getContents().forEach((contents) => readerStyleContents(contents));
  }
}

function readerStyleContents(contents) {
  if (!contents || !contents.document) {
    return;
  }
  const palette = READER_THEMES[readerTheme];
  // Every text container follows the surface ink: publisher rules like
  // `p { color: #000 }` would otherwise paint near-invisible text on the
  // dark paper. Code/pre keep their own colors.
  const flowText =
    "body, p, li, div, span, h1, h2, h3, h4, h5, h6, blockquote, figcaption, td, th, dd, dt";
  const rules = {
    html: {
      "background-color": `${palette.background} !important`,
      "color": `${palette.ink} !important`,
      "color-scheme": palette.scheme,
    },
    // Kills tap delay / double-tap zoom inside the reading surface.
    "html, body": {
      "touch-action": "manipulation",
    },
    [flowText]: {
      "color": "inherit !important",
      "background-color": "transparent !important",
    },
  };
  if (readerTypography) {
    // Root size on html; body and the common flow containers forced to
    // inherit it, so publisher rules like `p { font-size: 14px }` cannot
    // pin glyphs and ignore the preference.
    rules.html["font-size"] = `${readerTypography.fontSize}${readerTypography.unit} !important`;
    rules.body = {
      "line-height": `${readerTypography.lineHeight} !important`,
    };
    rules["body, p, li, div"] = {
      "font-size": "inherit !important",
    };
    // Publisher sheets commonly justify body text; ragged-right reads
    // better and avoids the uneven word spacing justification creates.
    // Headings and other display elements keep their own alignment.
    rules["body, p, li, dd, dt, blockquote, td, th, figcaption"] = {
      "text-align": "left !important",
    };
  }
  // With a face chosen, html carries the family and everything that
  // usually pins one inherits it; code/pre keep their monospace.
  if (readerFontFace) {
    rules.html["font-family"] = `${READER_FONT_FACES[readerFontFace]} !important`;
    rules[flowText] = Object.assign(rules[flowText], {
      "font-family": "inherit !important",
    });
  }
  contents.addStylesheetRules(rules);
  console.log(
    `readerStyleContents: theme=${readerTheme}` +
      (readerTypography
        ? ` ${readerTypography.fontSize}${readerTypography.unit}`
        : "") +
      ` face=${readerFontFace || "publisher"} rules=${Object.keys(rules).length}`,
  );
}

// Typeface (called from Swift): a key into READER_FONT_FACES, or anything
// unknown to leave publisher fonts standing.
function readerSetFontFace(face) {
  readerFontFace = Object.prototype.hasOwnProperty.call(READER_FONT_FACES, face) ? face : null;
  if (readerRendition) {
    readerRendition.getContents().forEach((contents) => readerStyleContents(contents));
  }
  readerTypographyRevision += 1;
  // Different glyphs re-break lines; the column count can change.
  readerApplyPageLayout();
  if (readerRendition) {
    readerQueueRelayout();
  }
}

// Forward relocation to the shell: page position within the chapter for the
// progress footer, plus the section href and the exact CFI so the shell can
// follow chapter changes made by paging across boundaries and save the
// reading position.
function readerReportRelocated(location) {
  // Withheld while a reflow transaction is mid-flight: the engine emits
  // locations for the half-relaid-out book, and publishing one would
  // overwrite the shell's stable anchor with a provisional page.
  if (readerLayoutInFlight) {
    return;
  }
  const start = location && location.start;
  const displayed = (start && start.displayed) || {};
  // Only a trusted relocation updates the reflow anchor. The engine also
  // re-displays on its own window-resize handler, and those locations
  // belong to a layout that is about to be replaced.
  const trusted = !readerLayoutWorkPending() || readerPendingNavigations > 0;
  if (start && start.cfi && trusted) {
    readerSettledCfi = start.cfi;
  }
  readerPost({
    type: "relocated",
    href: start && start.href ? start.href : null,
    cfi: start && start.cfi ? start.cfi : null,
    page: displayed.page || 1,
    totalPages: displayed.total || 0,
  });
}

// Tap zones: DOM clicks bridge to the shell through the script message
// handler (the Apple-documented web→native channel). WKWebView's private
// tap recognizers starve any UITapGestureRecognizer attached to the
// container on device, but clicks always fire — links and selection
// prove the event pipeline. Capture phase, registered before the link
// handler, so the zone logic sees every click. The click lands in the
// section iframe, so the x is mapped into the parent viewport (the frame
// is one wide translated column) against the parent's inner width.
function readerAttachTapZone(doc) {
  if (!doc || !doc.defaultView) {
    return;
  }
  doc.addEventListener(
    "click",
    (event) => {
      try {
        const frame = doc.defaultView.frameElement;
        const frameLeft = frame ? frame.getBoundingClientRect().left : 0;
        const parent = doc.defaultView.parent;
        const width = parent ? parent.innerWidth : 0;
        readerPost({ type: "tap", x: Math.round(frameLeft + event.clientX), width: Math.round(width) });
      } catch (error) {}
    },
    true,
  );
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
  readerInvalidatePendingLayout();
  readerBeginNavigation();
  try {
    readerCurrentTarget = target || null;
    // No target at all still means "open the book": epub.js starts at the
    // first section.
    const displayed = rendition.display(readerResolveSpineTarget(target));
    setTimeout(() => console.log("readerOpen: display still pending after 6s"), 6000);
    await displayed;
    console.log("readerOpen: display resolved for", target || "chapter start");
    readerCaptureSettledCfi();
  } finally {
    // The destination is on screen; the fragment refinement below is a
    // second pass that must not keep a reflow waiting on "navigation".
    readerEndNavigation();
  }

  const hashAt = target ? target.indexOf("#") : -1;
  if (hashAt == -1) {
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
    readerCaptureSettledCfi();
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
  if (!delta) {
    return;
  }
  // A user page turn is a navigation: it invalidates any pending re-anchor
  // so a layout transaction cannot drag the reader back to its old page.
  readerNavigationToken += 1;
  readerInvalidatePendingLayout();
  readerBeginNavigation();
  const done = () => {
    readerEndNavigation();
    // The turn finished: whatever page is on screen is the passage a later
    // reflow must preserve.
    readerCaptureSettledCfi();
  };
  const turn = delta > 0 ? readerRendition.next() : readerRendition.prev();
  turn.then(done, done);
  turn.catch(readerShowError);
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
    readerNavigationToken += 1;
    readerInvalidatePendingLayout();
    const displayed = readerRendition.display(location.end.cfi);
    displayed.then(readerCaptureSettledCfi, () => {});
    displayed.catch(readerShowError);
  }
}

window.readerOpen = readerOpen;
window.readerDisplay = readerDisplay;
window.readerScrollBy = readerScrollBy;
window.readerScrollTop = readerScrollTop;
window.readerScrollBottom = readerScrollBottom;
window.readerApplyTypography = readerApplyTypography;
window.readerSetFontFace = readerSetFontFace;
window.readerSetTheme = readerApplyTheme;
window.readerRelayout = readerQueueRelayout;
// Desktop layout API: the shell selects the mode; the page resolves the
// effective geometry. Exposed resolver is pure and used by the tests'
// numeric policy cases.
window.readerSetPageLayout = readerSetPageLayout;
window.readerResolveLayout = readerResolveLayout;
window.readerPageLayoutState = function () {
  return {
    requested: readerRequestedLayout,
    effective: readerEffectiveLayoutMode(),
    applied: readerAppliedLayout,
    previousPages: readerPreviousPages,
    glyphWidthPx: readerBodyGlyphWidth(),
    desktop: readerIsDesktop,
    // True while layout work or a navigation is queued or in flight; tests
    // wait on this instead of guessing at engine timings.
    settling: !!(
      readerLayoutInFlight ||
      readerRelayoutTimer !== null ||
      readerLayoutUpdateTimer !== null ||
      readerLayoutFrame !== null ||
      readerPendingNavigations > 0
    ),
  };
};
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

// Clicks on the top document itself (viewer padding, error page): the
// section listeners cannot see them across the frame boundary.
document.addEventListener(
  "click",
  (event) => {
    readerPost({ type: "tap", x: Math.round(event.clientX), width: Math.round(window.innerWidth) });
  },
  true,
);

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
