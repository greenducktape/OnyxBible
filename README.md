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

Scripture is **bundled in the app** for fully offline reading. The default
translation is the **King James Version** (Public Domain), shipped as per-book
JSON under `assets/bibles/kjv/` and loaded lazily.

The data layer (`lib/scripture.dart`) is multi-translation and multi-language:
each translation is a folder `assets/bibles/<id>/` plus a `TranslationInfo`
registry entry, so additional public-domain translations (e.g. World English
Bible, Spanish Reina-Valera 1909, German Luther 1912) are drop-in additions.
Non-bundled translations can optionally be fetched from
[bible-api.com](https://bible-api.com).

KJV text normalized from the public-domain [aruljohn/Bible-kjv](https://github.com/aruljohn/Bible-kjv) dataset.

## Getting started

```sh
flutter pub get
flutter run        # deploy to a connected Onyx Boox device
flutter test       # run the widget test
```

## Releasing (signing for the store)

Release builds fall back to the debug key when no keystore is configured, so an
APK always assembles. To produce a **store-signed** build, generate an upload
keystore once:

```sh
keytool -genkey -v -keystore upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

For local signed builds, put `android/key.properties` (gitignored):

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

For CI signing, add these repository **secrets** — the `Build APK` workflow then
signs automatically:

- `ANDROID_KEYSTORE_BASE64` — `base64 -w0 upload-keystore.jks`
- `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`

Keep the keystore and passwords private; losing them means you can't ship
updates under the same app identity (`com.onyxbible.reader`).

## License

App code is under the MIT License (`LICENSE`). Bundled scripture is public
domain; cross-reference data is OpenBible.info under CC-BY 4.0; fonts are under
the SIL Open Font License — see `NOTICE.md` and the in-app **About** screen.
