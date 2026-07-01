# Private / local translations

This folder is for **copyrighted** Bible translations (e.g. NVI, RV1960, LBLA)
that you have obtained legally and want to use **only on your own device**.

**Nothing real in this folder is ever committed.** `.gitignore` tracks only
`.gitkeep`, this `README.md`, and `manifest.example.json`. Every actual
translation file and the real `manifest.json` are ignored, so a copyrighted text
can never reach the public GitHub repo. A public/CI build finds no `manifest.json`
here and simply lists no private translations.

## How it works

1. You legally obtain a translation's text (a licensed copy, or a personal-use
   file). This project does not, and will not, download or ship those texts.
2. You run the importer, which converts your file(s) into one bundled JSON per
   translation and registers it in `manifest.json` — both written **here**, both
   gitignored:

   ```sh
   python3 tool/build_private_translation.py \
     --id nvi \
     --name "Nueva Versión Internacional" \
     --language "Español" \
     --attribution "© Biblica, Inc. — uso privado" \
     --zefania private_sources/nvi.xml
   ```

   Put your raw source files under `private_sources/` (also gitignored). The
   importer accepts a Zefania XML file (`--zefania`), a directory of per-book
   JSON in this repo's bundled shape (`--book-dir`), or a single combined JSON
   (`--json`). See the tool's `--help`.
3. Build the app locally (`flutter build apk` / `flutter run`). Your private
   translations appear in the "Print your Bible" setup, right alongside the
   public-domain ones.

## Switching between versions

Each printed Bible locks to one translation and keeps its own handwritten notes.
To read the same passage in NVI vs. RV1960, print one Bible per version and
switch between them in **Menu → My Bibles**. Notes stay with their Bible.

## Format written here (for reference)

`assets/bibles_private/<id>.json`:

```json
{
  "id": "nvi",
  "books": {
    "Genesis": { "1": [ { "v": 1, "t": "…" } ] }
  }
}
```

Book keys are the canonical English names used across the app (see
`lib/books.dart`); verse ids stay language-independent so notes carry across
translations.
