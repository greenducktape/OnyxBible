#!/usr/bin/env python3
"""Build the bundled cross-reference assets used by reading plans.

Input : the OpenBible.info cross-reference dataset (CC-BY 4.0), a TSV of
        `From Verse \t To Verse \t Votes` using OSIS-ish book codes, e.g.
        https://raw.githubusercontent.com/scrollmapper/bible_databases/master/sources/extras/cross_references.txt
Outputs (under assets/data/):
  xref_chapters.json — undirected chapter-level affinity graph:
    { "Book C": [["Book C2", weight], ...top-N...], ... }.
  ot_nt_echoes.json — for each OT chapter, top-K New Testament passages
    (a contiguous verse range in a NT chapter) whose cross-references most
    strongly echo it. Shape:
    { "Genesis 1": [{"book":"Hebrews","chapter":11,"from":1,"to":3,"votes":N}, ...], ... }
    This is what gives the cross-referenced plan its Emmaus-style snippet feel
    (the OT main track paired each day with a short NT echo, not a whole NT
    chapter).

We never ship the 340k-row verse dataset or compute it on device.

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

TOP_N = 10  # strongest chapter neighbours kept per chapter
ECHO_TOP_K = 5  # strongest NT echo passages kept per OT chapter
ECHO_MAX_RANGE = 10  # cap NT echo range at this many verses (snippet, not chapter)
REF_RE = re.compile(r'^([0-9A-Za-z]+)\.(\d+)\.(\d+)')

OT_CODES = set(CODES[:39])
NT_CODES = set(CODES[39:])


def chapter_of(ref):
    """('Gen.1.1' or a 'Gen.1.1-Gen.1.5' range start) -> 'Genesis 1' or None."""
    start = ref.split('-')[0].strip()
    m = REF_RE.match(start)
    if not m:
        return None
    name = CODE_TO_NAME.get(m.group(1))
    return f'{name} {int(m.group(2))}' if name else None


def parse_ref(ref):
    """('Gen.1.1') -> (code, chapter, verse) or None. Range end is also parsed."""
    start = ref.split('-')[0].strip()
    m = REF_RE.match(start)
    if not m:
        return None
    return m.group(1), int(m.group(2)), int(m.group(3))


def parse_verse_range(ref):
    """Returns (code, chapter, from_verse, to_verse) for the source verse range.
    A single verse 'Gen.1.1' has from==to. Ranges 'Heb.11.1-Heb.11.3' span the
    inclusive interval. Cross-chapter ranges (rare) collapse to the start verse.
    """
    parsed = parse_ref(ref)
    if parsed is None:
        return None
    code, chapter, from_v = parsed
    to_v = from_v
    if '-' in ref:
        end_parsed = parse_ref(ref.split('-', 1)[1])
        if end_parsed is not None:
            end_code, end_chapter, end_v = end_parsed
            if end_code == code and end_chapter == chapter and end_v >= from_v:
                to_v = end_v
    return code, chapter, from_v, to_v


def densest_range(verse_votes, max_range):
    """Given {verse: votes}, return (from_v, to_v, total_votes) for the
    contiguous range of at most [max_range] verses with the largest sum.
    Simple sliding window over the sparse sorted verse list."""
    if not verse_votes:
        return None
    verses = sorted(verse_votes.keys())
    best_from = best_to = verses[0]
    best_sum = verse_votes[verses[0]]
    for i, vstart in enumerate(verses):
        running = 0
        for j in range(i, len(verses)):
            vend = verses[j]
            if vend - vstart + 1 > max_range:
                break
            running += verse_votes[vend]
            if running > best_sum:
                best_sum = running
                best_from = vstart
                best_to = vend
    return best_from, best_to, best_sum


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    weights = defaultdict(lambda: defaultdict(int))
    # echoes_raw[ot_chapter][(nt_code, nt_chapter)][nt_verse] = summed votes
    echoes_raw = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))

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
            weights[a][b] += votes
            weights[b][a] += votes

            # OT <- NT verse-level echo collection. Treat the side that lives
            # in the NT as the "echo" passage, the OT side as the chapter
            # being echoed. Either direction of the row can carry that.
            for ot_ref, nt_ref in ((parts[0], parts[1]), (parts[1], parts[0])):
                ot_parsed = parse_ref(ot_ref)
                nt_parsed = parse_verse_range(nt_ref)
                if ot_parsed is None or nt_parsed is None:
                    continue
                ot_code, ot_chapter, _ = ot_parsed
                nt_code, nt_chapter, nt_from, nt_to = nt_parsed
                if ot_code not in OT_CODES or nt_code not in NT_CODES:
                    continue
                ot_key = f'{CODE_TO_NAME[ot_code]} {ot_chapter}'
                nt_key = (nt_code, nt_chapter)
                # Distribute votes evenly across the NT source verse range.
                span = max(1, nt_to - nt_from + 1)
                per_verse = max(1, votes // span)
                for v in range(nt_from, nt_to + 1):
                    echoes_raw[ot_key][nt_key][v] += per_verse

    # Chapter-level adjacency graph (unchanged from v1).
    graph = {}
    for ch, nbrs in weights.items():
        top = sorted(nbrs.items(), key=lambda kv: (-kv[1], kv[0]))[:TOP_N]
        graph[ch] = [[name, w] for name, w in top]

    out_chapters = 'assets/data/xref_chapters.json'
    with open(out_chapters, 'w') as f:
        json.dump(graph, f, separators=(',', ':'), sort_keys=True)
    print(f'{len(graph)} chapters -> {out_chapters}')

    # OT -> NT verse-range echoes (the snippet feed for the cross-ref plan).
    echoes_out = {}
    for ot_key, nt_buckets in echoes_raw.items():
        ranges = []
        for (nt_code, nt_chapter), verse_votes in nt_buckets.items():
            r = densest_range(verse_votes, ECHO_MAX_RANGE)
            if r is None:
                continue
            f_v, t_v, total = r
            if total <= 0:
                continue
            ranges.append({
                'book': CODE_TO_NAME[nt_code],
                'chapter': nt_chapter,
                'from': f_v,
                'to': t_v,
                'votes': total,
            })
        # Sort strongest-first; tie-break canonically.
        ranges.sort(key=lambda r: (-r['votes'], r['book'], r['chapter'], r['from']))
        if ranges:
            echoes_out[ot_key] = ranges[:ECHO_TOP_K]

    out_echoes = 'assets/data/ot_nt_echoes.json'
    with open(out_echoes, 'w') as f:
        json.dump(echoes_out, f, separators=(',', ':'), sort_keys=True)
    print(f'{len(echoes_out)} OT chapters with NT echoes -> {out_echoes}')


if __name__ == '__main__':
    main()
