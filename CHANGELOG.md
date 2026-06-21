# Changelog

All notable changes to Onyx Bible are recorded here. Dates are ISO 8601.

## [Unreleased]

### Added
- **Minimal two-zone reader**: one unified toolbar plus a full-height canvas.
  Pens, eraser, undo/redo, page navigation, and the plan-day indicator all live
  in a single bar; the bottom bar is gone so the page extends to the screen edge.
- **Kindle-style page turning**: tap the left/right edge of the page with a
  finger to turn pages (stylus always writes).
- **Palm rejection** ("ignore touch"): a hand toggle that makes the app respond
  to the pen only, so a resting hand can't flip pages; on-bar `<`/`>` arrows
  appear as the alternative way to turn pages. Persists across launches.
- **Emmaus-style cross-referenced reading plans**: each day pairs the Old
  Testament reading with a short New Testament passage (a verse range) whose
  cross-references most strongly echo it, instead of marching through Matthew.
- **About screen** with version, credits, attributions, a privacy statement,
  and the full open-source license list.

### Changed
- All saved data (notes, library, plans, settings) is now written **atomically**
  with a backup copy, and notes are flushed the moment a stroke is lifted and
  when the app is backgrounded — protecting against data loss on power loss.

### Fixed
- Long book titles no longer overflow the toolbar.

## [1.0.0]
- First sideload-ready build: offline KJV / Reina-Valera 1909 / Luther 1912,
  "Print your Bible" setup, multi-Bible library, stylus notes, search, notes
  browser, and reading plans.
