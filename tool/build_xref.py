#!/usr/bin/env python3
"""Build the bundled chapter cross-reference graph used by reading plans.

Input : the OpenBible.info cross-reference dataset (CC-BY 4.0), a TSV of
        `From Verse \t To Verse \t Votes` using OSIS-ish book codes, e.g.
        https://raw.githubusercontent.com/scrollmapper/bible_databases/master/sources/extras/cross_references.txt
Output: assets/data/xref_chapters.json — a compact, undirected chapter-level
        affinity graph: { "Book C": [["Book C2", weight], ...top-N...], ... }.

We never ship the 340k-row verse dataset or compute it on device. Verse links
are aggregated to chapter pairs (summed votes), self/intra-chapter links are
dropped, and only the strongest few neighbours per chapter are kept, which is
plenty to pair a chapter with its best cross-referenced partner.

Usage: python3 tool/build_xref.py path/to/cross_references.txt

Attribution (required by CC-BY) is surfaced in the app's About screen.
"""
import json
import re
import sys
from collections import defaultdict

# Canonical names (must match lib/books.dart order) paired with the OSIS codes
# the dataset uses. Zipped positionally, so order matters.
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

TOP_N = 10  # strongest neighbours kept per chapter
REF_RE = re.compile(r'^([0-9A-Za-z]+)\.(\d+)\.\d+')


def chapter_of(ref):
    """('Gen.1.1' or a 'Gen.1.1-Gen.1.5' range start) -> 'Genesis 1' or None."""
    start = ref.split('-')[0].strip()
    m = REF_RE.match(start)
    if not m:
        return None
    name = CODE_TO_NAME.get(m.group(1))
    return f'{name} {int(m.group(2))}' if name else None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    weights = defaultdict(lambda: defaultdict(int))
    with open(sys.argv[1]) as f:
        next(f)  # header
        for line in f:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 3:
                continue
            a = chapter_of(parts[0])
            b = chapter_of(parts[1])
            try:
                votes = int(parts[2])
            except ValueError:
                continue
            if a is None or b is None or a == b or votes <= 0:
                continue
            # Undirected: both chapters learn about the link.
            weights[a][b] += votes
            weights[b][a] += votes

    graph = {}
    for ch, nbrs in weights.items():
        top = sorted(nbrs.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
        graph[ch] = [[name, w] for name, w in top]

    out = 'assets/data/xref_chapters.json'
    with open(out, 'w') as f:
        json.dump(graph, f, separators=(',', ':'), sort_keys=True)
    print(f'{len(graph)} chapters -> {out}')


if __name__ == '__main__':
    main()
