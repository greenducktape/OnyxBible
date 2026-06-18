# Onyx Bible

A distraction-free Bible reader and handwriting app for Onyx Boox e-ink
devices, built with Flutter. Read scripture in a clean, book-like layout and
annotate verses directly with the stylus.

## Features

- **Full canon navigation** — pick any of the 66 books and jump to any chapter
  from the built-in picker. Chapter/page controls roll across book boundaries.
- **Handwriting on verses** — write notes on top of any verse with the pen.
  Strokes are saved per verse and persist between sessions.
- **Stroke-level eraser** — the eraser (or the pen's inverted/eraser tip)
  removes only the marks you touch, not the whole verse.
- **Offline reading** — chapters are cached on disk after the first fetch, so
  previously read chapters open without a network connection. The next chapter
  is prefetched in the background.
- **Tuned for e-ink** — high-contrast typography, full-screen refresh on page
  turns to clear ghosting, and a pen pipeline that repaints only the drawing
  canvas (not the text) so writing stays responsive.

## Architecture notes

- `lib/main.dart` — app, reader screen, persistence, and the verse/handwriting
  widgets.
- `lib/books.dart` — the 66-book canon data and chapter-navigation helpers.

### Why writing stays smooth

Stylus input is captured by a `Listener` on each verse. While a stroke is in
progress, only a dedicated `CustomPaint` repaints (driven by a `ValueNotifier`
passed as its `repaint` listenable) — no widget rebuilds and no text relayout
happen per pen sample. `onyxsdk_pen` then accelerates those `CustomPaint`
repaints on Onyx hardware. Committed strokes are stored per verse without
triggering rebuilds of neighbouring verses.

## Scripture source

Text is fetched from [bible-api.com](https://bible-api.com) (World English
Bible) and cached locally.

## Getting started

```sh
flutter pub get
flutter run        # deploy to a connected Onyx Boox device
flutter test       # run the widget test
```
