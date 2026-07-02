#!/usr/bin/env python3
"""Import a PRIVATE, copyrighted translation you legally own into the app.

This script only *converts* a file you already have — it never downloads or
contains any scripture text. Its output lands under assets/bibles_private/,
which is gitignored, so a copyrighted translation can never reach the repo.

Input (pick one):
  --zefania FILE     Zefania XML (a common format for offline Bible modules)
  --book-dir DIR     a directory of per-book JSON in this repo's bundled shape
                     ({"chapters": {"1": [{"v": 1, "t": "..."}]}}), one file per
                     book named like "1_Samuel.json"
  --json FILE        a single JSON file, either {"books": {...}} or a bare
                     {book: {chapter: [{"v","t"}]}} mapping
  --items-json FILE  a chapter-rendered export keyed by USFM book codes
                     ({"books": [{"book_usfm": "GEN", "chapters": [{"items":
                     [{"type": "verse", "verse_numbers": [1], "lines": [...]
                     }]}]}]})

Output:
  assets/bibles_private/<id>.json        the translation, app format
  assets/bibles_private/manifest.json    upserted with this translation's metadata

Example:
  python3 tool/build_private_translation.py \\
    --id nvi --name "Nueva Versión Internacional" --language "Español" \\
    --attribution "© Biblica, Inc. — uso privado" \\
    --zefania private_sources/nvi.xml
"""
import argparse
import json
import os
import sys
import xml.etree.ElementTree as ET

# Canonical book names in order, matching lib/books.dart. Zefania files identify
# books by a 1-based number; we map that number to these names so verse ids stay
# language-independent and notes carry across translations.
CANON = [
    'Genesis', 'Exodus', 'Leviticus', 'Numbers', 'Deuteronomy', 'Joshua',
    'Judges', 'Ruth', '1 Samuel', '2 Samuel', '1 Kings', '2 Kings',
    '1 Chronicles', '2 Chronicles', 'Ezra', 'Nehemiah', 'Esther', 'Job',
    'Psalms', 'Proverbs', 'Ecclesiastes', 'Song of Solomon', 'Isaiah',
    'Jeremiah', 'Lamentations', 'Ezekiel', 'Daniel', 'Hosea', 'Joel', 'Amos',
    'Obadiah', 'Jonah', 'Micah', 'Nahum', 'Habakkuk', 'Zephaniah', 'Haggai',
    'Zechariah', 'Malachi', 'Matthew', 'Mark', 'Luke', 'John', 'Acts',
    'Romans', '1 Corinthians', '2 Corinthians', 'Galatians', 'Ephesians',
    'Philippians', 'Colossians', '1 Thessalonians', '2 Thessalonians',
    '1 Timothy', '2 Timothy', 'Titus', 'Philemon', 'Hebrews', 'James',
    '1 Peter', '2 Peter', '1 John', '2 John', '3 John', 'Jude', 'Revelation',
]
CANON_SET = set(CANON)
OUT_DIR = 'assets/bibles_private'


def _verses(pairs):
    """[(verse_no, text)] -> [{"v":n,"t":text}], dropping blanks."""
    out = []
    for n, t in pairs:
        t = (t or '').strip()
        if t:
            out.append({'v': int(n), 't': t})
    return out


def from_zefania(path):
    """Zefania XMLBIBLE -> {book: {chapter: [{v,t}]}} keyed by canonical name."""
    root = ET.parse(path).getroot()
    books = {}
    for book_el in root.iter('BIBLEBOOK'):
        num = book_el.get('bnumber')
        if num is None or not num.isdigit() or not (1 <= int(num) <= 66):
            continue
        name = CANON[int(num) - 1]
        chapters = {}
        for ch_el in book_el.iter('CHAPTER'):
            cnum = ch_el.get('cnumber')
            if cnum is None:
                continue
            pairs = []
            for v_el in ch_el.iter('VERS'):
                vnum = v_el.get('vnumber')
                # Zefania text can include inline markup; itertext() flattens it.
                text = ''.join(v_el.itertext())
                if vnum is not None:
                    pairs.append((vnum, text))
            vs = _verses(pairs)
            if vs:
                chapters[str(int(cnum))] = vs
        if chapters:
            books[name] = chapters
    return books


def from_book_dir(path):
    books = {}
    for fn in sorted(os.listdir(path)):
        if not fn.endswith('.json'):
            continue
        name = fn[:-5].replace('_', ' ')
        if name not in CANON_SET:
            print(f'  skip {fn}: "{name}" is not a canonical book name')
            continue
        with open(os.path.join(path, fn)) as f:
            data = json.load(f)
        chapters = data.get('chapters', data)
        clean = {}
        for cnum, verses in chapters.items():
            clean[str(int(cnum))] = _verses(
                [(v['v'], v.get('t', v.get('text', ''))) for v in verses])
        books[name] = clean
    return books


def from_json(path):
    with open(path) as f:
        data = json.load(f)
    books = data.get('books', data)
    out = {}
    for name, chapters in books.items():
        if name not in CANON_SET:
            print(f'  skip "{name}": not a canonical book name')
            continue
        out[name] = {
            str(int(c)): _verses(
                [(v['v'], v.get('t', v.get('text', ''))) for v in verses])
            for c, verses in chapters.items()
        }
    return out


# Standard 3-letter USFM book codes, positionally matching CANON. Used by
# chapter-rendered exports that identify books by code ("GEN", "1SA", ...).
USFM_CODES = [
    'GEN', 'EXO', 'LEV', 'NUM', 'DEU', 'JOS', 'JDG', 'RUT', '1SA', '2SA',
    '1KI', '2KI', '1CH', '2CH', 'EZR', 'NEH', 'EST', 'JOB', 'PSA', 'PRO',
    'ECC', 'SNG', 'ISA', 'JER', 'LAM', 'EZK', 'DAN', 'HOS', 'JOL', 'AMO',
    'OBA', 'JON', 'MIC', 'NAM', 'HAB', 'ZEP', 'HAG', 'ZEC', 'MAL', 'MAT',
    'MRK', 'LUK', 'JHN', 'ACT', 'ROM', '1CO', '2CO', 'GAL', 'EPH', 'PHP',
    'COL', '1TH', '2TH', '1TI', '2TI', 'TIT', 'PHM', 'HEB', 'JAS', '1PE',
    '2PE', '1JN', '2JN', '3JN', 'JUD', 'REV',
]
USFM_TO_NAME = dict(zip(USFM_CODES, CANON))


def from_items_json(path):
    """Chapter-rendered export: {"books": [{"book_usfm": "GEN", "chapters":
    [{"chapter_usfm": "GEN.1", "is_chapter": true, "items": [{"type": "verse",
    "verse_numbers": [1], "lines": ["..."]}]}]}]}. Headings/labels (any item
    whose type isn't "verse") are dropped; a verse split across several items
    is merged in order.
    """
    with open(path) as f:
        data = json.load(f)
    books = {}
    for b in data.get('books', []):
        name = USFM_TO_NAME.get(b.get('book_usfm'))
        if name is None:
            print(f'  skip book code {b.get("book_usfm")!r}: not in the canon')
            continue
        chapters = {}
        for ch in b.get('chapters', []):
            if not ch.get('is_chapter'):
                continue
            num = str(ch.get('chapter_usfm', '')).split('.')[-1]
            if not num.isdigit():
                continue
            parts = {}  # verse number -> [text parts, in document order]
            for it in ch.get('items', []):
                if it.get('type') != 'verse':
                    continue
                vn = it.get('verse_numbers') or []
                if len(vn) != 1:
                    continue
                text = ' '.join(
                    ln.strip() for ln in (it.get('lines') or []) if ln and ln.strip())
                if text:
                    parts.setdefault(int(vn[0]), []).append(text)
            verses = _verses([(v, ' '.join(parts[v])) for v in sorted(parts)])
            if verses:
                chapters[str(int(num))] = verses
        if chapters:
            books[name] = chapters
    return books


def upsert_manifest(entry):
    path = os.path.join(OUT_DIR, 'manifest.json')
    manifest = []
    if os.path.exists(path):
        with open(path) as f:
            manifest = json.load(f)
    manifest = [m for m in manifest if m.get('id') != entry['id']]
    manifest.append(entry)
    manifest.sort(key=lambda m: m['id'])
    with open(path, 'w') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    return path


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--id', required=True, help='short id, e.g. nvi')
    ap.add_argument('--name', required=True, help='display name')
    ap.add_argument('--language', default='Español')
    ap.add_argument('--attribution', required=True,
                    help='copyright / usage note shown in the app')
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument('--zefania', metavar='FILE')
    src.add_argument('--book-dir', metavar='DIR')
    src.add_argument('--json', metavar='FILE')
    src.add_argument('--items-json', metavar='FILE',
                     help='chapter-rendered export keyed by USFM codes '
                          '(books[].book_usfm / chapters[].items[])')
    args = ap.parse_args()

    if args.zefania:
        books = from_zefania(args.zefania)
    elif args.book_dir:
        books = from_book_dir(args.book_dir)
    elif args.items_json:
        books = from_items_json(args.items_json)
    else:
        books = from_json(args.json)

    if not books:
        print('No books parsed — check the input format.', file=sys.stderr)
        sys.exit(1)

    os.makedirs(OUT_DIR, exist_ok=True)
    out_path = os.path.join(OUT_DIR, f'{args.id}.json')
    with open(out_path, 'w') as f:
        json.dump({'id': args.id, 'books': books}, f, ensure_ascii=False)

    manifest_path = upsert_manifest({
        'id': args.id,
        'displayName': args.name,
        'language': args.language,
        'attribution': args.attribution,
    })

    total = sum(len(ch) for ch in books.values())
    print(f'Wrote {out_path}: {len(books)} books, {total} chapters')
    print(f'Updated {manifest_path}')
    print('Both files are gitignored — they will not be committed.')


if __name__ == '__main__':
    main()
