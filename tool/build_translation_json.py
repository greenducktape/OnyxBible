#!/usr/bin/env python3
"""Convert a thiagobodruk-format JSON Bible into the app's per-book assets.

Input : a single JSON file shaped as 66 books in canonical order:
          [{"abbrev":"gn","name":"...","chapters":[[v1,v2,...],[...]]}, ...]
        e.g. the public-domain Reina-Valera 1909 (old orthography):
          https://raw.githubusercontent.com/thiagobodruk/bible/master/json/es_rvr.json
Output: assets/bibles/<id>/<Book>.json — same shape as the KJV bundle.

Books are mapped positionally to the canonical English names, so navigation and
note ids stay language-independent. See build_translation.py for the OSIS path.

Usage: python3 tool/build_translation_json.py <bible.json> <id> [out_dir]
"""
import json
import os
import sys

NAMES = [
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


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src, translation_id = sys.argv[1], sys.argv[2]
    out_dir = sys.argv[3] if len(sys.argv) > 3 else f'assets/bibles/{translation_id}'
    os.makedirs(out_dir, exist_ok=True)

    with open(src, encoding='utf-8-sig') as f:
        data = json.load(f)
    if len(data) != 66:
        raise SystemExit(f'expected 66 books, got {len(data)}')

    total = 0
    for i, book in enumerate(data):
        name = NAMES[i]
        chapters = {}
        for ci, verses in enumerate(book['chapters']):
            rows = []
            for vi, text in enumerate(verses):
                t = ' '.join(str(text).split()).strip()
                if t:
                    rows.append({'v': vi + 1, 't': t})
            if rows:
                chapters[str(ci + 1)] = rows
                total += len(rows)
        slug = name.replace(' ', '_')
        with open(os.path.join(out_dir, f'{slug}.json'), 'w',
                  encoding='utf-8') as f:
            json.dump({'translation': translation_id, 'book': name,
                       'chapters': chapters}, f, ensure_ascii=False,
                      separators=(',', ':'))
    print(f'{translation_id}: 66 books, {total} verses -> {out_dir}')


if __name__ == '__main__':
    main()
