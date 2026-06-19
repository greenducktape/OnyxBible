#!/usr/bin/env python3
"""Convert a public-domain OSIS-XML Bible into the app's per-book JSON assets.

Input : an OSIS XML file (verses as <verse osisID='Gen.1.1'>text</verse>),
        e.g. the gratis-bible mirror (public domain):
          https://raw.githubusercontent.com/gratis-bible/bible/master/de/luth1912.xml
          https://raw.githubusercontent.com/gratis-bible/bible/master/es/rva.xml
Output: assets/bibles/<id>/<Book>.json, one per book, matching the KJV bundle:
          {"translation":"<id>","book":"<English name>",
           "chapters":{"1":[{"v":1,"t":"..."}]}}

Book navigation and note ids stay in canonical English regardless of the text's
language, so handwritten notes remain compatible across every translation.
Footnotes and section headings are dropped; only verse text is kept.

Usage: python3 tool/build_translation.py <osis.xml> <id> [out_dir]
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET

# OSIS book codes -> canonical English names (same order/list as build_xref.py).
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
CODES = [
    'Gen', 'Exod', 'Lev', 'Num', 'Deut', 'Josh', 'Judg', 'Ruth', '1Sam',
    '2Sam', '1Kgs', '2Kgs', '1Chr', '2Chr', 'Ezra', 'Neh', 'Esth', 'Job',
    'Ps', 'Prov', 'Eccl', 'Song', 'Isa', 'Jer', 'Lam', 'Ezek', 'Dan', 'Hos',
    'Joel', 'Amos', 'Obad', 'Jonah', 'Mic', 'Nah', 'Hab', 'Zeph', 'Hag',
    'Zech', 'Mal', 'Matt', 'Mark', 'Luke', 'John', 'Acts', 'Rom', '1Cor',
    '2Cor', 'Gal', 'Eph', 'Phil', 'Col', '1Thess', '2Thess', '1Tim', '2Tim',
    'Titus', 'Phlm', 'Heb', 'Jas', '1Pet', '2Pet', '1John', '2John', '3John',
    'Jude', 'Rev',
]
CODE_TO_NAME = dict(zip(CODES, NAMES))


def local(tag):
    return tag.rsplit('}', 1)[-1]


def verse_text(verse):
    # Drop footnotes / inline headings; keep added-word and name markup text.
    for child in list(verse):
        if local(child.tag) in ('note', 'title'):
            verse.remove(child)
    text = ''.join(verse.itertext())
    return re.sub(r'\s+', ' ', text).strip()


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    xml_path, translation_id = sys.argv[1], sys.argv[2]
    out_dir = sys.argv[3] if len(sys.argv) > 3 else f'assets/bibles/{translation_id}'
    os.makedirs(out_dir, exist_ok=True)

    tree = ET.parse(xml_path)
    # books[name] = { "1": [ {v,t}, ... ] }
    books, order, skipped = {}, [], set()
    for verse in tree.iter():
        if local(verse.tag) != 'verse':
            continue
        osis = verse.get('osisID')
        if not osis:
            continue
        parts = osis.split('.')
        if len(parts) != 3:
            continue
        code, ch, vs = parts
        name = CODE_TO_NAME.get(code)
        if name is None:
            skipped.add(code)  # apocrypha / non-canonical book
            continue
        text = verse_text(verse)
        if not text:
            continue
        if name not in books:
            books[name] = {}
            order.append(name)
        books[name].setdefault(ch, []).append({'v': int(vs), 't': text})

    for name in order:
        chapters = books[name]
        for ch in chapters:
            chapters[ch].sort(key=lambda e: e['v'])
        slug = name.replace(' ', '_')
        with open(os.path.join(out_dir, f'{slug}.json'), 'w',
                  encoding='utf-8') as f:
            json.dump({'translation': translation_id, 'book': name,
                       'chapters': chapters}, f, ensure_ascii=False,
                      separators=(',', ':'))

    total = sum(len(v) for b in books.values() for v in b.values())
    print(f'{translation_id}: {len(order)} books, {total} verses -> {out_dir}')
    if skipped:
        print(f'  skipped non-canonical books: {sorted(skipped)}')


if __name__ == '__main__':
    main()
