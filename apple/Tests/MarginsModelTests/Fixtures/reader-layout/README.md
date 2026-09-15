# Reader layout fixtures

Small, fully redistributable EPUBs used by `ReaderLayoutIntegrationTests`
to drive the real vendored epub.js renderer inside a macOS WKWebView.
None of them contain personal books, notes, or machine-specific paths.

| File | Shape | Exercises |
| --- | --- | --- |
| `reflowable.epub` | 5 spine sections, 35 uniquely identified paragraphs (`p-<section>-<nn>`), a 900×600 PNG plate, a cross-section fragment link (`ch1` → `ch3.xhtml#p-3-04`), publisher CSS that pins body font/justify, and a short 3-paragraph final section | automatic one/two-page decisions, page turns across chapter boundaries, odd final page, image aspect ratio, internal links |
| `rtl.epub` | 2 right-to-left sections (`page-progression-direction="rtl"`, `dir="rtl"`) | safe single-page fallback for unverified writing modes |
| `fixed-layout.epub` | 2 pre-paginated 1024×768 sections (`rendition:layout` = `pre-paginated`) | fixed-layout content never receives reflowable two-column rules |

Rebuild them with the Python standard library (no network, no Node):

```bash
python3 scripts/make-reader-layout-fixtures.py
```

The generator pins ZIP timestamps and entry order, so reruns are
byte-identical. Built EPUBs are committed so `swift test` reads
deterministic bytes without a generation step.
