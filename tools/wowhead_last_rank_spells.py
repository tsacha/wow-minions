#!/usr/bin/env python3
"""
Fetch Wowhead WotLK Classic spell list pages, parse embedded `listviewspells` JSON,
filter by spell school bitmask, and print one row per spell name (highest rank).

Multi-class (repeat `--class`, or `--all-classes` / `--all-sources`):

    python3 tools/wowhead_last_rank_spells.py --class warrior --class mage --school-mask 4
    python3 tools/wowhead_last_rank_spells.py --all-classes --school-mask 0
    python3 tools/wowhead_last_rank_spells.py --all-sources --school-mask 0

`--all-classes` = 10 playable classes only.
`--all-sources` = those 10 + Wowhead lists **pet**, **racial**, **glyphs** (familiers / traits
raciaux / glyphes — pas des classes jouables, mais souvent utiles à côté).

`--school-mask 0` disables school filtering (all schools from that page).

Default mask: **32 (Shadow)** only when you run the script with *no* arguments (implicit priest
page). For `--class`, `--url`, `--all-classes`, or `--all-sources`, the default is **0** (no school
filter) so warriors, pets, etc. are not emptied by accident — pass `--school-mask 32` yourself when
you want Shadow-only on priest (or any other bitmask for another school).

Single custom URL (cannot combine with `--class` / `--all-classes` / `--all-sources`):

    python3 tools/wowhead_last_rank_spells.py \\
        --url 'https://www.wowhead.com/wotlk/spells/abilities/priest' \\
        --school-mask 32

School bits (classic WoW): Physical=1 Holy=2 Fire=4 Nature=8 Frost=16 Shadow=32 Arcane=64

Wowhead embeds near-JSON: unquoted keys `quality` and `popularity` are normalized before json.loads.
Optional smoke check: --tooltips uses nether.wowhead.com JSON tooltips (often works when www CDN blocks).
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
import urllib.error
import urllib.request
from collections import defaultdict
from typing import Any

LISTVIEW_PREFIX = "listviewspells = ["
WOTLK_SPELLS_BASE = "https://www.wowhead.com/wotlk/spells"
WOTLK_ABILITIES_BASE = f"{WOTLK_SPELLS_BASE}/abilities"

# Slugs match the final path segment on Wowhead WotLK *class* ability lists.
CLASS_SLUGS: tuple[str, ...] = (
    "death-knight",
    "druid",
    "hunter",
    "mage",
    "paladin",
    "priest",
    "rogue",
    "shaman",
    "warlock",
    "warrior",
)

# Extra Wowhead spell lists (same `listviewspells` format, different URL path).
EXTRA_SOURCES: dict[str, str] = {
    "pet": f"{WOTLK_SPELLS_BASE}/pet-abilities",
    "racial": f"{WOTLK_SPELLS_BASE}/racial-traits",
    "glyphs": f"{WOTLK_SPELLS_BASE}/glyphs",
}

# English / shorthand aliases -> playable class slug or extra key
_SOURCE_ALIASES: dict[str, str] = {
    "dk": "death-knight",
    "deathknight": "death-knight",
    "death_knight": "death-knight",
    "pets": "pet",
    "racials": "racial",
    "racial-traits": "racial",
    "racial_traits": "racial",
    "glyph": "glyphs",
}

# French (ASCII-folded keys) -> playable class slug
_FR_CLASS: dict[str, str] = {
    "guerrier": "warrior",
    "paladin": "paladin",
    "chasseur": "hunter",
    "voleur": "rogue",
    "pretre": "priest",
    "demoniste": "warlock",
    "chaman": "shaman",
    "mage": "mage",
    "druide": "druid",
    "chevalier-de-la-mort": "death-knight",
}

USER_AGENT = (
    "Mozilla/5.0 (compatible; wow-minions/wowhead_last_rank_spells; +https://github.com/)"
)


def fold_key(s: str) -> str:
    """Lowercase ASCII-ish key: strip accents, spaces -> hyphens."""
    nk = unicodedata.normalize("NFKD", s.strip())
    plain = "".join(c for c in nk if unicodedata.category(c) != "Mn")
    plain = plain.lower().replace("_", "-")
    plain = re.sub(r"\s+", "-", plain)
    plain = re.sub(r"-+", "-", plain).strip("-")
    return plain


def abilities_url(class_slug: str) -> str:
    return f"{WOTLK_ABILITIES_BASE}/{class_slug}"


def resolve_source(raw: str) -> tuple[str, str]:
    """
    Return (label, url) for a --class token.
    `label` is the canonical key used in TSV (class column).
    """
    key = fold_key(raw)
    key = _SOURCE_ALIASES.get(key, key)
    if key in EXTRA_SOURCES:
        return (key, EXTRA_SOURCES[key])
    key = _FR_CLASS.get(key, key)
    key = _SOURCE_ALIASES.get(key, key)
    if key in CLASS_SLUGS:
        return (key, abilities_url(key))
    known = ", ".join(sorted(set(CLASS_SLUGS) | set(EXTRA_SOURCES)))
    raise ValueError(f"unknown source {raw!r} (resolved {key!r}); known: {known}")


def fetch(url: str, timeout_s: float) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout_s) as resp:
        return resp.read().decode("utf-8", errors="replace")


def extract_listview_array(html: str) -> str:
    i0 = html.find(LISTVIEW_PREFIX)
    if i0 < 0:
        raise ValueError("Could not find listviewspells = [ in HTML (Wowhead layout changed?)")
    bracket_open = i0 + len(LISTVIEW_PREFIX) - 1
    assert html[bracket_open] == "[", "internal: expected '[' after prefix"
    depth = 0
    for i in range(bracket_open, len(html)):
        c = html[i]
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return html[bracket_open : i + 1]
    raise ValueError("Unbalanced brackets while scanning listviewspells array")


def js_array_to_json(blob: str) -> str:
    # Wowhead uses JavaScript object literals: ,quality:-1 ,popularity:N
    return blob.replace(",quality:", ',"quality":').replace(",popularity:", ',"popularity":')


def parse_rank(rank: str | None) -> int:
    if not rank:
        return 0
    m = re.match(r"^Rank\s+(\d+)\s*$", rank.strip(), re.I)
    return int(m.group(1)) if m else 0


def best_entry_key(entry: dict[str, Any]) -> tuple[int, int, int]:
    """Higher tuple = preferred (last rank)."""
    rank_n = parse_rank(entry.get("rank"))
    level = int(entry.get("level") or 0)
    sid = int(entry["id"])
    return (rank_n, level, sid)


def pick_last_rank_per_name(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for e in entries:
        by_name[str(e["name"])].append(e)
    out: list[dict[str, Any]] = []
    for name in sorted(by_name.keys()):
        rows = by_name[name]
        best = max(rows, key=best_entry_key)
        out.append(best)
    return out


def fetch_tooltip_json(spell_id: int, timeout_s: float) -> dict[str, Any]:
    url = f"https://nether.wowhead.com/wotlk/tooltip/spell/{spell_id}"
    raw = fetch(url, timeout_s)
    return json.loads(raw)


def process_page(html: str, school_mask: int) -> list[dict[str, Any]]:
    """Return last-rank winners after optional school filter."""
    blob = extract_listview_array(html)
    arr: list[dict[str, Any]] = json.loads(js_array_to_json(blob))
    if school_mask == 0:
        filtered = arr
    else:
        filtered = [x for x in arr if int(x.get("schools") or 0) & school_mask]
    return pick_last_rank_per_name(filtered)


def main() -> int:
    n_extra = len(EXTRA_SOURCES)
    n_class = len(CLASS_SLUGS)
    epilog = (
        f"Playable classes ({n_class}, --all-classes): "
        + ", ".join(CLASS_SLUGS)
        + f"\nExtra lists ({n_extra}, included in --all-sources): "
        + ", ".join(sorted(EXTRA_SOURCES))
        + "\nAliases: dk -> death-knight ; pets -> pet ; racials -> racial ; glyph -> glyphs\n"
        + "French class names: guerrier, chasseur, pretre, demoniste, chaman, druide, chevalier-de-la-mort, …\n"
        + "School mask: no args → default Shadow (32); with --class/--url/--all-* → default 0 (no filter).\n"
    )
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=epilog,
    )
    src = parser.add_mutually_exclusive_group()
    src.add_argument(
        "--url",
        default=None,
        help="Single custom Wowhead WotLK spell list URL (must contain listviewspells). "
        "Cannot be used with --class / --all-classes / --all-sources.",
    )
    src.add_argument(
        "--class",
        action="append",
        dest="classes",
        metavar="CLASS",
        help="Class slug, extra key (pet, racial, glyphs), or alias (repeat for multiple).",
    )
    src.add_argument(
        "--all-classes",
        action="store_true",
        help=f"Fetch all {n_class} playable class abilities pages.",
    )
    src.add_argument(
        "--all-sources",
        action="store_true",
        help=f"Fetch all {n_class} classes plus {n_extra} extra lists ({n_class + n_extra} requests).",
    )
    parser.add_argument(
        "--list-classes",
        action="store_true",
        help="Print class + extra source slugs and URLs, then exit.",
    )
    parser.add_argument(
        "--school-mask",
        type=int,
        default=None,
        metavar="N",
        help="Bitmask: keep spells where (schools & N) != 0; use 0 for no filter. "
        "Default: 32 (Shadow) only for the implicit no-arg priest scrape; "
        "default 0 when using --class / --url / --all-*.",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="HTTP timeout in seconds",
    )
    parser.add_argument(
        "--format",
        choices=("tsv", "json"),
        default="tsv",
        help="Output format",
    )
    parser.add_argument(
        "--tooltips",
        action="store_true",
        help="After listing, GET nether.wowhead.com tooltip JSON for each spell_id (smoke test)",
    )
    args = parser.parse_args()

    implicit_priest_only = (
        not args.url
        and not args.classes
        and not args.all_classes
        and not args.all_sources
    )
    if args.school_mask is None:
        school_mask = 32 if implicit_priest_only else 0
    else:
        school_mask = int(args.school_mask)

    if args.list_classes:
        print("# playable classes")
        for slug in CLASS_SLUGS:
            print(f"{slug}\t{abilities_url(slug)}")
        print("# extra lists (not playable classes)")
        for slug in sorted(EXTRA_SOURCES):
            print(f"{slug}\t{EXTRA_SOURCES[slug]}")
        return 0

    pages: list[tuple[str, str]] = []
    if args.url:
        label = args.url.rstrip("/").split("/")[-1] or "custom"
        pages.append((label, args.url))
    elif args.all_sources:
        for slug in CLASS_SLUGS:
            pages.append((slug, abilities_url(slug)))
        for slug in sorted(EXTRA_SOURCES):
            pages.append((slug, EXTRA_SOURCES[slug]))
    elif args.all_classes:
        for slug in CLASS_SLUGS:
            pages.append((slug, abilities_url(slug)))
    elif args.classes:
        for raw in args.classes:
            try:
                label, url = resolve_source(raw)
            except ValueError as e:
                print(str(e), file=sys.stderr)
                return 2
            pages.append((label, url))
    else:
        # Backward compatible default: priest + Shadow filter
        pages.append(("priest", abilities_url("priest")))

    multi = len(pages) > 1
    all_winners: list[tuple[str, dict[str, Any]]] = []
    errors = 0

    for label, url in pages:
        try:
            html = fetch(url, args.timeout)
        except urllib.error.URLError as e:
            print(f"fetch failed ({label}): {url}: {e}", file=sys.stderr)
            errors += 1
            continue
        try:
            winners = process_page(html, school_mask)
        except (ValueError, json.JSONDecodeError) as e:
            print(f"parse failed ({label}): {e}", file=sys.stderr)
            errors += 1
            continue
        for w in winners:
            all_winners.append((label, w))

    if not all_winners:
        print(
            "no spell rows produced (empty after --school-mask filter? try --school-mask 0)",
            file=sys.stderr,
        )
        return 1 if errors else 2

    if args.format == "tsv":
        if multi:
            print("class\tspell_id\tname\tlevel\trank\tschools")
            for cls, w in all_winners:
                print(
                    f"{cls}\t{w['id']}\t{w['name']}\t{w.get('level', '')}\t{w.get('rank', '')}\t{w.get('schools', '')}"
                )
        else:
            print("spell_id\tname\tlevel\trank\tschools")
            for _, w in all_winners:
                print(
                    f"{w['id']}\t{w['name']}\t{w.get('level', '')}\t{w.get('rank', '')}\t{w.get('schools', '')}"
                )
    else:
        out = [{"class": cls, **w} for cls, w in all_winners]
        json.dump(out, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")

    if args.tooltips:
        for cls, w in all_winners:
            sid = int(w["id"])
            try:
                tip = fetch_tooltip_json(sid, args.timeout)
                tname = tip.get("name", "?")
                tag = f"{cls} " if multi else ""
                print(f"# tooltip {tag}{sid} -> {json.dumps(tname)}", file=sys.stderr)
            except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
                print(f"# tooltip {cls} {sid} FAILED: {e}", file=sys.stderr)

    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
