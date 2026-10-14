#!/usr/bin/env python3
"""Regenerate the Unicode / Arabic shaping tables used by the PDF engine.

    python3 -m venv .venv && ./.venv/bin/pip install "arabic-reshaper" "python-bidi"
    python3 tool/gen_unicode_tables.py

Outputs (checked into the repo so the app needs no code generation):
  * lib/services/pdf/shaping/data/bidi_classes.dart
  * lib/services/pdf/shaping/data/bidi_mirrored.dart
  * lib/services/pdf/shaping/data/arabic_forms.dart

Sources:
  * Unicode bidi classes  -> CPython's unicodedata (UCD)
  * Bidi mirroring pairs  -> python-bidi
  * Arabic letter forms   -> arabic-reshaper (MIT)
"""
from __future__ import annotations

import os
import re
import unicodedata

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "lib", "services", "pdf", "shaping", "data")
HEADER = ("// GENERATED FILE - do not edit by hand.\n"
          "// Regenerate with: python3 tool/gen_unicode_tables.py\n"
          "// ignore_for_file: lines_longer_than_80_chars\n\n")

# --------------------------------------------------------------------- bidi
BIDI_ORDER = ['L', 'R', 'AL', 'EN', 'ES', 'ET', 'AN', 'CS', 'NSM', 'BN', 'B', 'S', 'WS', 'ON']
BIDI_IDS = {name: i for i, name in enumerate(BIDI_ORDER)}


def bidi_ranges():
    """Merged [start, end, classId] triples; anything unlisted defaults to L."""
    ranges = []
    cur = None
    for cp in range(0x110000):
        if 0xD800 <= cp <= 0xDFFF:
            continue
        name = unicodedata.bidirectional(chr(cp))
        cls = name if name in BIDI_IDS else 'ON'
        if cls == 'L':  # default: omitted from the table
            cur = None
            continue
        if cur and cur[2] == cls and cp == cur[1] + 1:
            cur[1] = cp
        else:
            if cur:
                ranges.append(tuple(cur))
            cur = [cp, cp, cls]
    if cur:
        ranges.append(tuple(cur))
    return ranges


def write_bidi_classes():
    ranges = bidi_ranges()
    out = [HEADER, "/// Bidi class ids (mirrors [BidiClass] in bidi.dart).\n",
           "const int bidiL = 0;\nconst int bidiR = 1;\nconst int bidiAL = 2;\n"
           "const int bidiEN = 3;\nconst int bidiES = 4;\nconst int bidiET = 5;\n"
           "const int bidiAN = 6;\nconst int bidiCS = 7;\nconst int bidiNSM = 8;\n"
           "const int bidiBN = 9;\nconst int bidiB = 10;\nconst int bidiS = 11;\n"
           "const int bidiWS = 12;\nconst int bidiON = 13;\n\n"
           "/// Flat (start, end, classId) triples, sorted by start.\n"
           "/// Code points that are absent from this list are left-to-right.\n"
           "const List<int> bidiClassRanges = <int>[\n"]
    for start, end, cls in ranges:
        out.append(f"  {start}, {end}, {BIDI_IDS[cls]},\n")
    out.append("];\n")
    with open(os.path.join(DATA, "bidi_classes.dart"), "w", encoding="utf-8") as f:
        f.writelines(out)
    return len(ranges)


def write_bidi_mirrored():
    from bidi.mirror import MIRRORED
    pairs = sorted(MIRRORED.items(), key=lambda kv: ord(kv[0]))
    out = [HEADER, "/// Flat (codePoint, mirroredCodePoint) pairs for UAX#9 rule L4.\n",
           "const List<int> bidiMirroredPairs = <int>[\n"]
    for a, b in pairs:
        out.append(f"  0x{ord(a):04X}, 0x{ord(b):04X},\n")
    out.append("];\n")
    with open(os.path.join(DATA, "bidi_mirrored.dart"), "w", encoding="utf-8") as f:
        f.writelines(out)
    return len(pairs)


# ------------------------------------------------------------------- arabic
HARAKAT_RANGES = [
    (0x0610, 0x061A), (0x064B, 0x065F), (0x0670, 0x0670),
    (0x06D6, 0x06DC), (0x06DF, 0x06E8), (0x06EA, 0x06ED),
    (0x08D4, 0x08E1), (0x08D4, 0x08ED), (0x08E3, 0x08FF),
]


def write_arabic_forms():
    from arabic_reshaper.letters import (LETTERS_ARABIC, ISOLATED, INITIAL,
                                         MEDIAL, FINAL, TATWEEL, ZWJ)

    def cp(value):
        return hex(ord(value)) if value else "0"

    out = [HEADER,
           "/// Arabic letter -> presentation forms.\n"
           "///\n"
           "/// Each entry is `[isolated, initial, medial, final]`; `0` means the\n"
           "/// letter has no glyph for that form (and therefore does not join on\n"
           "/// that side).\n"
           "const Map<int, List<int>> arabicLetterForms = <int, List<int>>{\n"]
    for letter, forms in sorted(LETTERS_ARABIC.items(), key=lambda kv: ord(kv[0])):
        if letter in (TATWEEL, ZWJ):
            continue
        values = []
        for form in (ISOLATED, INITIAL, MEDIAL, FINAL):
            f = forms[form] if form < len(forms) else ''
            values.append(cp(f) if f else "0")
        out.append(f"  {hex(ord(letter))}: <int>[{', '.join(values)}],\n")
    out.append("};\n\n")

    # harakat (diacritics) ranges
    out.append("/// Ranges of combining marks (harakat) that are carried along, not joined.\n")
    out.append("const List<int> arabicHarakatRanges = <int>[\n")
    for a, b in HARAKAT_RANGES:
        out.append(f"  0x{a:04X}, 0x{b:04X},\n")
    out.append("];\n\n")

    # ligatures
    from arabic_reshaper.ligatures import LIGATURES
    out.append("/// Longest-match Arabic ligatures: (sequence, [iso, initial, medial, final]).\n")
    out.append("const List<({String sequence, List<int> forms})> arabicLigatures = <({String sequence, List<int> forms})>[\n")
    entries = []
    for _name, (match, forms) in LIGATURES:
        if not match:
            continue
        entries.append((match, forms))
    entries.sort(key=lambda e: (-len(e[0]), e[0]))
    for match, forms in entries:
        values = ", ".join(cp(f) if f else "0" for f in forms)
        escaped = "".join(f"\\u{ord(ch):04X}" for ch in match)
        out.append(f"  (sequence: '{escaped}', forms: <int>[{values}]),\n")
    out.append("];\n")

    with open(os.path.join(DATA, "arabic_forms.dart"), "w", encoding="utf-8") as f:
        f.writelines(out)
    return len(LETTERS_ARABIC), len(entries)


if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    n1 = write_bidi_classes()
    n2 = write_bidi_mirrored()
    n3, n4 = write_arabic_forms()
    print(f"bidi ranges: {n1}, mirrored pairs: {n2}, arabic letters: {n3}, ligatures: {n4}")
