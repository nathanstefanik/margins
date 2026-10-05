# Checking the macOS app by hand (and by agent)

How to drive `build/Margins.app` for runtime checks without touching the
user's own library or settings. The WebKit suites
(`docs/testing/macos-reader-layout.md`) cover the reader engine; this is for
everything else: views, overlays, keys, hover.

## Launch the build you just made

- `make app`, then launch the binary directly so you control its
  environment and know which copy is running:

  ```bash
  MARGINS_DATA_DIR=/tmp/margins-check/data \
  MARGINS_LIBRARY_ROOT=/tmp/margins-check/library \
    build/Margins.app/Contents/MacOS/Margins &
  ```

- Don't launch by name (`open -a Margins`, `tell application "Margins"`).
  An installed `/Applications/Margins.app` has the same bundle id
  (`io.github.nathanstefanik.margins`), and LaunchServices may start that
  copy instead. Activate the window by pid, and check the pid's executable
  path when in doubt.
- Seed the library under `/tmp` from
  `apple/Tests/MarginsCoreTests/Fixtures/legacy-library/` or by importing
  fixture EPUBs. To give a book progress, write a `position.json`; a
  position of 99% or more files it under Finished. Never point
  `MARGINS_LIBRARY_ROOT` at the user's library.

## Preferences are shared with the user's real app

The build reads and writes the same defaults domain as the user's
installed app (`~/Library/Preferences/io.github.nathanstefanik.margins.plist`;
the `make app` build isn't sandboxed). That includes `reader.*` keys and
the per-chapter `notePrompt.dismissed.<book>.<chapter>` silences.

- Before changing settings, record the current values
  (`defaults read io.github.nathanstefanik.margins`).
- When you're done, restore them, or `defaults delete` only the keys you
  added.
- If you flip the system appearance to test Match system (`osascript -e
  'tell app "System Events" to tell appearance preferences to set dark mode
  to not dark mode'`), flip it back.

## Synthetic input

- Keys: `osascript -e 'tell app "System Events" to key code …'` or
  `keystroke`, once the build's window is frontmost. Page turns are
  ArrowRight, PageDown, and Space; `l` goes back to the library.
- Pointer: `cliclick` (Homebrew) posts real events. `cliclick m:x,y` fires
  hover and tracking areas, such as the footer scrubber and the focus-mode
  footer fade. `CGWarpMouseCursorPosition` alone moves the cursor without
  firing them.
- Screenshots: `screencapture -l <windowid>` or `-R x,y,w,h`; keep them
  under `/tmp` and report the paths.
