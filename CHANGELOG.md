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
- **Bundled reading fonts** (Crimson Pro, EB Garamond, Lora, Atkinson
  Hyperlegible) so the app is fully offline from the first launch — no font
  download on a fresh device.
- **Backup & restore**: export everything (Bibles, notes, plans, settings) to a
  single file via the share sheet, and restore it later. Nothing is stored in
  the cloud, so this is the off-device safety net.

### Changed
- **Large-screen support**: the toolbar, menus, and controls now scale up on big
  e-ink panels (e.g. the 13.3" Boox Max), with an "Interface size" override in
  the menu. Larger print font sizes added. Inking is smoother on long strokes —
  sub-pixel points are decimated and the in-progress stroke composites on its own
  layer, so writing near the margins no longer slows down.
- All saved data (notes, library, plans, settings) is now written **atomically**
  with a backup copy, and notes are flushed the moment a stroke is lifted and
  when the app is backgrounded — protecting against data loss on power loss.

### Fixed
- Long book titles no longer overflow the toolbar.

## [1.0.0]
- First sideload-ready build: offline KJV / Reina-Valera 1909 / Luther 1912,
  "Print your Bible" setup, multi-Bible library, stylus notes, search, notes
  browser, and reading plans.
