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
- **Start a reading plan anywhere**: the plan builder has a "Start from" book/
  chapter picker, with a toggle to either wrap around and still cover the whole
  Bible or stop at the end (a shorter plan from that point on).
- **Private, local-only translations**: drop legally-obtained copyrighted
  versions (e.g. NVI, RV1960, LBLA) into a gitignored folder via
  `tool/build_private_translation.py`; they appear in the setup wizard and are
  readable/searchable offline. They can never be committed to the repo.

### Changed
- **Cleaner navigation**: the menu opens as a left drawer (where the burger is),
  Interface size is a centred dialog, the page arrows are always in the bar (no
  more shifting when toggling palm rejection), and the nib-size row floats over
  the canvas instead of reflowing the page. Printed margins now match what the
  setup preview shows.
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
- The chapter header no longer overflows its reserved space on the first page.
- Plan lists now show a snippet echo's verse range ("Hebrews 11:1-3") instead of
  truncating it to the whole chapter.
- Rapid pen lifts can no longer race two saves of the notes file into a corrupt
  write — per-file writes are serialised.
- The toolbar shrinks gracefully on narrow/portrait screens instead of
  overflowing.

## [1.0.0]
- First sideload-ready build: offline KJV / Reina-Valera 1909 / Luther 1912,
  "Print your Bible" setup, multi-Bible library, stylus notes, search, notes
  browser, and reading plans.
