# Third-party content and licenses

Onyx Bible's own source code is under the MIT License (see `LICENSE`). The
bundled content and dependencies below keep their original licenses.

## Scripture texts (bundled, offline)

All bundled translations are in the public domain:

- **King James Version (KJV)** — English. Public Domain. Normalised from the
  `aruljohn/Bible-kjv` dataset.
- **Reina-Valera 1909 (RV1909)** — Spanish. Dominio público (public domain).
  From the `gratis-bible` mirror.
- **Luther 1912** — German. Gemeinfrei (public domain). From the `gratis-bible`
  mirror.

Build scripts that reproduce the bundled JSON live in `tool/`.

## Cross-reference data

- **OpenBible.info cross-references** — Creative Commons Attribution 4.0
  International (CC-BY 4.0). Aggregated to a chapter/verse-range graph by
  `tool/build_xref.py` into `assets/data/xref_chapters.json` and
  `assets/data/ot_nt_echoes.json`. Attribution is surfaced in the app's
  **About** screen, as required by CC-BY.

## Typefaces

- **Crimson Pro**, **EB Garamond**, **Lora**, **Atkinson Hyperlegible** — each
  under the **SIL Open Font License (OFL)**.

## Vendored packages

- **packages/onyxsdk_pen** — BSD 3-Clause License (see
  `packages/onyxsdk_pen/LICENSE`).

The full dependency license list is also available in-app under
**About → Open-source licenses** (Flutter's license registry).
