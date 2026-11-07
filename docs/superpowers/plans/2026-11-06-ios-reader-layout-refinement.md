# iOS Reader Layout Refinement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS reading page fill its column and sit lower, and replace the page-slider rail with a simpler glass control layout that keeps Contents at the bottom left.

**Architecture:** The right-edge and bottom fixes are small changes to the iOS path of the shared reader page (`reader.js`, `reader.html`). The chrome change is confined to `ReaderScene.swift`: the footer takes the same shape as the header, an overlay of glass buttons that never reflows the page.

**Tech Stack:** SwiftUI (iOS 26+ glass APIs, built with the iOS 27.2 SDK), epub.js in WKWebView, Swift Testing.

**Spec:** The request below, plus `docs/ios-reader-chrome.md`, which Task 3 updates.

## The request

1. The right side looks too padded, which makes the text uneven.
2. Reduce the bottom padding by half a line to a line.
3. Remove the in-chapter slider and reorganize the pop-up controls, keeping Contents, perhaps at the bottom left.
4. Follow current iOS 27.2 guidance for translucent glass.
5. Include the version bump as a commit.

## Findings

### Right edge: `text-wrap: pretty` is the cause

`IMG_0002` is a 393×852pt screen (scale 2.35), showing Easy at step 2 (14px).

- The text box is symmetric. Viewer padding 22.4 plus epub.js gap/2 14 gives 36.4pt each side, leaving a 320.2pt column. The screenshot's left margin of 86px agrees.
- No line on that page ends closer than 162px (69pt) to the screen edge, so about 33pt of the column is never used.
- `readerStyleContents` sets `text-wrap: pretty` on all prose. Rendering the screenshot's text in WebKit at 320.2pt reproduces every line break of its two complete paragraphs with `pretty`, and the breaks differ without it. There is no hidden narrower box.
- Easy never justifies (`readerJustify && readerFontFace !== "easy"`), so the Justify toggle cannot help on this face.

Gap between line end and column edge, in pt, on the screenshot's text:

| Setting | Mode | Mean gap | Worst gap |
|---|---|---|---|
| Easy 14px | `pretty` (today) | 48.8 | 86.4 |
| Easy 14px | **no `pretty` (this plan)** | **21.0** | 58.7 |
| Easy 14px | no `pretty` + hyphens | 16.1 | 36.4 |
| Easy 18px | `pretty` (today) | 46.5 | 76.0 |
| Easy 18px | **no `pretty` (this plan)** | **24.4** | 110.9 |
| Serif 18px | `pretty` (today) | 37.5 | 78.2 |
| Serif 18px | **no `pretty` (this plan)** | **23.7** | 65.2 |
| Serif 18px | no `pretty` + hyphens | 16.4 | 32.4 |

These runs used macOS WebKit, not iOS WebKit, on about 25 lines of text. The exact line-break match is the strong evidence; treat the means as indicative. Ragged text keeps some natural rag, and an occasional line can be worse than today (Easy 18px above), because a long word simply wraps.

### Bottom: there is a line of slack, and the page number limits it

Measured on the same screenshot, in pt from the top of an 852pt screen:

- Column bottom: 766 (safe area 818, minus `#viewer` 32, minus epub.js body padding 20).
- Last line's ink bottom: 739. Page number: 775 to 784.
- `.safeAreaPadding(.bottom)` with no length adds the 16pt default padding, not the home-indicator inset. The overlay is already inside the safe area, so this raises the page number by 16pt for no reason.

Moving the column down 16pt alone would let a full column touch the number, so the number moves down 16pt with it. At 14px Easy the column grows from 652 to 668pt, and the page gains exactly one line (25 to 26). Other sizes gain a line only when the slack allows, because a column holds whole lines.

### Glass: why the rail looks like a dark slab

- The rail follows the **system** appearance, while the paper has its own palette (`ReaderScene.swift:126`). A dark-mode phone on Sepia paper therefore gets dark glass over cream, as in `IMG_0003`.
- Xcode 27.2's bundled Liquid Glass guide asks for `GlassEffectContainer` around multiple glass views, `.interactive()` on controls, and consistent shapes. The rail skips the container.
- The 27.2 SDK adds no glass API: `Glass`, `.clear`, and `glassEffectUnion` are all iOS 26.0. Press coverage of iOS 27 reports better diffusion of busy content, a darkened edge, and a Settings transparency slider, all of which apply to standard glass without app changes ([MacRumors](https://www.macrumors.com/2026/06/10/how-liquid-glass-is-changing-in-ios-27/)). Sources disagree on whether 27 is more or less translucent overall.
- Keep `.regular`. `.clear` is meant for rich media, and these controls sit over body text. That reading of `.clear` comes from the iOS 26 HIG as remembered: the current HIG page could not be fetched, and the Xcode guide does not cover `.clear`. Task 3 checks this on a device.
- Keep overlays rather than a system `.bottomBar`. A bottom bar changes the safe area, which would break the documented rule that showing chrome never reflows the page.

## Decisions for review

| # | Decision | Default in this plan | Alternative |
|---|---|---|---|
| 1 | Version | **0.8.0**: `[Unreleased]` already holds the local-first library, and this adds a chrome redesign | 0.7.2 |
| 2 | Deployment target | **Stay at iOS 26.0**: no 27-only API is needed, and raising it drops iOS 26 readers | Raise to 27.0 |
| 3 | Chapter chevrons | **Keep, at the bottom right.** Only the slider was asked to go | Remove them and leave Contents alone |
| 4 | Easy's right edge | **Stays ragged**, as its accessibility design intends | Allow Justify on Easy (mean gap 0pt) |
| 5 | Hyphenation in ragged text | **Off**: a modest gain, and hyphens cost low-vision readers | On for Serif and Sans |

## Global Constraints

- macOS rendering must not change: gate `reader.js` changes on `readerIsDesktop`; `html.reader-macos #viewer` already overrides the `reader.html` padding.
- Showing chrome never reflows the page: no `safeAreaInset`, no system bottom bar.
- `IPHONEOS_DEPLOYMENT_TARGET` stays 26.0, and CI builds with Xcode 26.6, so use no API newer than iOS 26.
- Glass goes on the control plane only, never on content (AGENTS.md).
- Commit subjects are imperative sentences with no type prefixes; bodies wrap at 72 columns and end with `Assisted-by: Claude Code`.
- Do not push the branch or tag without explicit approval. Pushing `v*` triggers `release.yml`.

## Review Focus

1. **Largest text and Dynamic Type:** at step 6 (24px) and at accessibility text sizes, the last line stays clear of the page number. (Task 2, step 5)
2. **Small and home-button screens:** on a 375pt-wide screen and with no bottom safe area, the footer buttons are not clipped. (Task 3, step 6)
3. **Book edges:** in the first and last chapters a disabled chevron looks disabled and the pair keeps its shape. (Task 3, step 6)
4. **All four papers against both system appearances:** chrome stays legible, and sheets opened from it still follow the system. (Task 3, step 6)
5. **Saved places:** a bookmark and the saved position from before the update reopen on the same passage after repagination. (Task 1, step 4)

---

### Task 1: Let iOS text fill the column

**Files:**
- Modify: `apple/Sources/MarginsModel/Resources/reader/reader.js` (`rules[proseAlign]` in `readerStyleContents`)
- Test: `apple/Tests/MarginsModelTests/ReaderLayoutIntegrationTests.swift`

- [ ] **Step 1: Write the failing tests** in the `iOS preservation` section:

```swift
@Test("iOS prose fills the line; macOS keeps pretty wrapping")
func proseWrapPerPlatform() async throws {
    let script = """
        getComputedStyle(document.querySelector('iframe')
            .contentDocument.querySelector('p')).textWrapStyle
        """
    for (platform, expected) in [(nil, "auto"), ("macos", "pretty")] as [(String?, String)] {
        let harness = try makeHarness(width: 400, height: 760)
        defer { harness.dismantle() }
        try await harness.load(platform: platform, typography: (16, 1.65, 0, "px"))
        _ = try await harness.waitForRelocation(after: 0)
        #expect(try await harness.evaluate(script) as? String == expected)
    }
}
```

- [ ] **Step 2: Run it and confirm the iOS case fails**

Run: `swift test --package-path apple --filter ReaderLayoutIntegrationTests/proseWrapPerPlatform`
Expected: FAIL, `"pretty"` where `"auto"` is expected.

- [ ] **Step 3: Implement.** Drop `text-wrap` from the `rules[proseAlign]` literal and set it only `if (readerIsDesktop)`. Comment why: `pretty` shortens lines to even the rag and leaves the narrow phone column visibly under-filled.

- [ ] **Step 4: Run the suite and check saved places**

Run: `swift test --package-path apple --filter 'ReaderLayoutIntegrationTests|ReaderLayoutMatrixTests|ReaderRevealTests'`
Expected: PASS. In the simulator, bookmark a page, reopen the book, and confirm it lands on the same passage.

- [ ] **Step 5: Commit** as `Let iOS reader text fill the column`, with the measurements in the body and `Test:` naming the filter above.

### Task 2: Extend the page toward the footer

**Files:**
- Modify: `apple/Sources/MarginsModel/Resources/reader/reader.html` (`#viewer` padding and comment)
- Modify: `apple/ios/Margins/Reader/ReaderScene.swift` (`.overlay(alignment: .bottom)`, `footerOverlay`)
- Test: `apple/Tests/MarginsModelTests/ReaderLayoutIntegrationTests.swift`

**Produces:** the footer is a fixed `DesignTokens.Control.readerTarget` (48pt) tall in every state, so the page number holds still when Task 3 adds controls around it.

- [ ] **Step 1: Add to `iosPageIsUnchanged`:**

```swift
// Bottom padding: one rem, half a line or more above the footer.
let paddingBottom = try await harness.evaluate(
    "parseFloat(getComputedStyle(document.getElementById('viewer')).paddingBottom)"
) as? Double
#expect(abs((paddingBottom ?? 0) - 16) < 0.5)
```

- [ ] **Step 2: Run it**

Run: `swift test --package-path apple --filter ReaderLayoutIntegrationTests/iosPageIsUnchanged`
Expected: FAIL, 32 where 16 is expected.

- [ ] **Step 3: Implement.** Set `#viewer` padding to `2.2rem 1.4rem 1.0rem`. Remove `.safeAreaPadding(.bottom)` from the footer overlay, and correct the `footerOverlay` comment that says it pads into the safe area. Replace `.frame(height: chromeVisible ? nil : 44)` with `.frame(height: DesignTokens.Control.readerTarget)`.

- [ ] **Step 4: Run the test and build**

Run: `swift test --package-path apple --filter ReaderLayoutIntegrationTests/iosPageIsUnchanged && make ios-build`
Expected: PASS and `BUILD SUCCEEDED`.

- [ ] **Step 5: Check clearance in the simulator** (ios-simulator skill, iPhone 17). With a full page at steps 2, 4, and 6, and at the largest Dynamic Type size, the last line's descenders must not touch the page number. Save the screenshots.

- [ ] **Step 6: Commit** as `Extend the iOS reading page toward the footer`, with `Test:` naming the filter and the simulator check.

### Task 3: Replace the rail with glass controls

**Files:**
- Modify: `apple/ios/Margins/Reader/ReaderScene.swift` (`footerOverlay`, overlays, scrubber state, `scrubberRail`, `railButton`, header comment)
- Modify: `apple/ios/Margins/Reader/ReaderBridge.swift:273-275` (remove `goToPage`)
- Modify: `docs/ios-reader-chrome.md`, `README.md:17`, `CHANGELOG.md`

**Consumes:** Task 2's fixed-height footer.

**Layout, chrome up.** Same inset and height as the header; the page number stays where it is at rest:

```
[≡ Contents]          12 of 40          [ ‹  › ]
```

- [ ] **Step 1: Rebuild `footerOverlay`** as a `ZStack` mirroring `headerOverlay`:
  - Below: the existing `Text(pageText)`, unchanged and still `allowsHitTesting(false)`, shown in both states. `pageText` already handles `12 of 40`.
  - Above, `if chromeVisible`: a `GlassEffectContainer(spacing: DesignTokens.Spacing.chrome)` holding an `HStack(spacing: DesignTokens.Spacing.actions)` of Contents, a `Spacer(minLength: 0)`, then an inner `HStack(spacing: 0)` with the two chevrons. Add `.transition(.opacity)`.
  - Then `.padding(.horizontal, DesignTokens.Spacing.controlInset)`.
  - Use `chromeButton` for all three. Icons, labels, and identifiers:

| Control | Icon | Label | Identifier |
|---|---|---|---|
| Contents | `list.bullet` | Contents | `reader-contents` |
| Previous chapter | `chevron.backward` | Previous chapter | `reader-previous-chapter` |
| Next chapter | `chevron.forward` | Next chapter | `reader-next-chapter` |

  - Keep `.disabled(!canStepChapter(±1))` on the chevrons, and merge them with `.glassEffectUnion(id: "chapters", namespace:)` from a new `@Namespace private var chromeGlass`.
  - Drop the `reader.progress` requirement on the controls, so Contents is reachable while a chapter loads.

- [ ] **Step 2: Delete the scrubber.** Remove `scrubValue`, `scrubbing`, `scrubberRail`, `railButton`, and iOS `ReaderBridge.goToPage`. Keep `readerGoToPage` in `reader.js`, which macOS uses.

- [ ] **Step 3: Match glass to the paper.** Add `private var paperColorScheme: ColorScheme { reader.preferences.theme.isDayPaper ? .light : .dark }`, and apply `.environment(\.colorScheme, paperColorScheme)` to `headerOverlay` and `footerOverlay` only. Do not apply it to the root view: sheets must keep following the system. Add no opaque or tinted backing behind the glass.

- [ ] **Step 4: Update the docs.**
  - `docs/ios-reader-chrome.md`: Single tap (no scrubber rail; describe the new row), the padding values and hit-testing notes in Layout, and the `text-wrap` difference.
  - `README.md:17`: the scrubber is macOS-only.
  - `CHANGELOG.md` `[Unreleased]`: under Changed, the new controls and the fuller text column; under Removed, the iOS in-chapter page slider.

- [ ] **Step 5: Build**

Run: `make ios-build`
Expected: `BUILD SUCCEEDED`, with no remaining references: `grep -rn "scrub" apple/ios` prints nothing.

- [ ] **Step 6: Verify in the simulator** with `MARGINS_CHROME_FIXTURE=1` (iOS 26.5 is the only installed runtime):
  - Light and Sepia under system dark show light glass; Dark and Night under system light show dark glass. Sheets follow the system.
  - Revealing chrome leaves the text and page number in place (compare screenshots).
  - A center tap between the controls hides chrome. Left and right thirds still turn pages.
  - Contents opens the sheet. Chevrons change chapter and are disabled at the book's ends.
  - Time left and None indicators do not collide with the controls.
  - iPhone 17e and an iPad layout show no clipping. VoiceOver reaches all three controls.

- [ ] **Step 7: Commit** as `Replace the iOS page slider with glass chapter controls`, explaining the paper-matched glass in the body.

- [ ] **Step 8: User check on an iOS 27 device.** The simulator cannot show iOS 27 glass. If the glass is too heavy over text, trying `.clear` is a change to `chromeButton` alone.

### Task 4: Bump the version

Runs last, after every other commit. `CURRENT_PROJECT_VERSION` stays 22: the release workflow picks a fresh build number at upload time, checked against App Store Connect.

**Files:**
- Modify: `CHANGELOG.md`, and through `make bump`, `apple/VERSION` and `apple/ios/Margins.xcodeproj/project.pbxproj`

- [ ] **Step 1: Run the full verification**

Run: `swift test --package-path apple --skip 'ReaderLayoutIntegrationTests|ReaderLayoutMatrixTests|ReaderRevealTests' && swift test --package-path apple --filter 'ReaderLayoutIntegrationTests|ReaderLayoutMatrixTests|ReaderRevealTests' && make ios-build`
Expected: all pass.

- [ ] **Step 2: Date the changelog.** Add `## [0.8.0] - <today>` under an empty `## [Unreleased]`, add `[0.8.0]: https://github.com/nathanstefanik/margins/releases/tag/v0.8.0` at the top of the link list at the file's end, then `git add CHANGELOG.md`. The staged file rides in the bump commit.

- [ ] **Step 3: Bump**

Run: `make bump VERSION=0.8.0`
Expected: one commit, `Bump version to 0.8.0`, and a local tag `v0.8.0`.

- [ ] **Step 4: Confirm**

Run: `cat apple/VERSION && grep -c 'MARKETING_VERSION = 0.8.0;' apple/ios/Margins.xcodeproj/project.pbxproj && git show --stat --format=%s HEAD`
Expected: `0.8.0`, a count of `2`, and three changed files. Do not push the commit or the tag without approval.
