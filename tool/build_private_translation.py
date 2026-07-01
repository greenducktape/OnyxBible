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
    args = ap.parse_args()

    if args.zefania:
        books = from_zefania(args.zefania)
    elif args.book_dir:
        books = from_book_dir(args.book_dir)
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
