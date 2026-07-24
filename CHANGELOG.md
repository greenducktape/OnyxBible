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

- **Print craft**: a running header ("GENESIS 4:1–26") and a folio page number
  are set into each page's margins, and two new print-time options — decorated
  chapter initials (drop caps) and justified text — give new Bibles a genuinely
  book-like page. Existing printed Bibles are untouched.
- **Eraser ring**: while erasing, a thin ring shows the eraser's reach.

### Added
- **A pen panel instead of six nib buttons**: tapping the active pen a second
  time opens a sheet with the pen's texture, a continuous width slider (a wedge
  that thickens to the right, so the control looks like what it sets), `<`/`>`
  buttons for exact steps, and the ink shade. The width is stated in real
  millimetres, read from the panel's actual dot pitch rather than guessed from
  Flutter's 160dpi-relative ratio.
- **Ink shades**: black, grey and light grey. Only three, because the panel is
  greyscale and every other colour would arrive as one of these anyway. Greys
  now also survive to the live pen overlay, which previously rounded any grey
  to black or to invisible white.

### Changed
- **The brush and the pencil stop flattening out when a stroke settles.**
  Committed width was driven by stylus pressure alone, so whenever the pen
  reported little of it — which is most of ordinary writing — every point came
  out the same width and the mark landed as an even, characterless line. Width
  now follows speed as well: the brush swells where the hand slows and runs
  thin on a flick, which is most of what makes a brush look like one.
- **The pencil has grain again.** It was being painted as a solid line at 95%
  opacity, which is not what graphite does. It now lands as a faint body with
  tooth scattered over it — the same speckle every time, hashed from the
  stroke's own coordinates, so it can't crawl between refreshes.
- **Book names in the Bible's own language**: a Spanish Bible now reads
  "Génesis 1" and a German one "1. Mose 1" — in the chapter title, the printed
  page header, the contents list, the notes list, reading plans and search —
  instead of English names over non-English text. Search understands them too,
  with or without accents ("Génesis", "Genesis", "Sal 23", "1. Mose 1",
  "Johannes 3,16"). Nothing stored changes: notes, plans and reading positions
  stay keyed to the same chapters, so they follow you between translations.
- **Ink that settles into the page instead of being redrawn**: when the e-ink
  refresh hands a finished stroke from the pen overlay to the app, the line now
  keeps the shape and weight it was written with. Strokes are painted as one
  smooth anti-aliased shape rather than a chain of hard-edged segments (the
  "pixelated" look), stylus pressure is read on the pen's own scale so a light
  touch is no longer mistaken for the hardest possible press, pressure can only
  thin a line and never thicken it past the nib, a hairline never renders below
  one physical panel pixel, and fine detail survives because fewer samples are
  discarded. A translucent marker no longer darkens where it overlaps itself.
- **E-ink refresh discipline**: page turns no longer flash the panel black every
  time — partial updates carry several turns and a full refresh runs every 6th
  turn and on chapter changes. Loading spinners are static now, and screen
  changes cut instantly instead of animating (no smearing).
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
- **Sideloaded updates install in place** (no more "package conflicts with an
  existing package"): builds are now signed with a stable, committed sideload
  keystore instead of each CI runner's random debug key, so updating no longer
  requires uninstalling and losing data. One final reinstall is needed to move
  onto the new key (use About → Export backup / Restore).
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
