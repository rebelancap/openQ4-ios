#!/usr/bin/env python3
"""gen-ios-retained-overrides.py — loose retained-UI page fixes for the bundle (D-123).

    scripts/gen-ios-retained-overrides.py <vendor pak0 dir> <app baseoq4 dir>

Writes corrected copies of upstream retained-UI documents beside the paks, the
same LOOSE-override mechanism as guis/demo_menu.gui (gen-ios-demo-menu-gui.py):
the engine searches directories before pk4s, pak0's MD5 stays the one upstream's
tools produce, and vendor/ is never edited.

Fix 1 — the fourth-level Campaign pages take no pointer input (an upstream
generator bug, tools/ui/retained_menu_levels.py detail_page_frame): their
"titles" group is a full-canvas (960x720 dp) absolute box drawn above the page's
content without `pointer-events: none`, which every other page's titles group
carries (retained_subpage.py, retained_settings_page.py, retained_mp_page.py,
retained_arena.py, build_retained_screens.py). Every tap or click on the
Campaign difficulty page (campaign_skill.rui: difficulty tiles, Turbo, START
GAME, BACK) and the Chapters page (chapters.rui) hits "titles" and activates
nothing; only keys and a pad could leave them. Upstreaming candidate: add
`'pointer-events': ui.keyword('none')` to detail_page_frame's title_group.

Every edit asserts its match count (charter ground rule 3); a pin bump that
fixes the generator upstream makes this script fail loudly, which is the cue
to retire it.
"""
import os
import re
import sys

TITLES_FIX = ("guis/menu/campaign_skill.rui", "guis/menu/chapters.rui")
TITLES_RE = re.compile(r'("id": "titles",\n\s*"type": "group",\n(\s*)"properties": \{\n)')


def fix_titles(text, name):
    matches = TITLES_RE.findall(text)
    if len(matches) != 1:
        sys.exit(f"FATAL: {name}: expected exactly one 'titles' group, found {len(matches)}")
    block = re.search(r'"id": "titles",\n\s*"type": "group",\n\s*"properties": \{\n(.*?)\n\s*\}', text, re.S)
    if block is None:
        sys.exit(f"FATAL: {name}: cannot read the 'titles' properties")
    if "pointer-events" in block.group(1):
        sys.exit(f"FATAL: {name}: 'titles' already declares pointer-events — upstream fixed it; retire this override")
    indent = matches[0][1] + " "
    return TITLES_RE.sub(lambda m: m.group(1) + indent + '"pointer-events": {"type": "keyword", "value": "none"},\n', text, count=1)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src_root, out_root = sys.argv[1], sys.argv[2]
    for name in TITLES_FIX:
        src = os.path.join(src_root, name)
        with open(src, encoding="utf-8") as f:
            text = f.read()
        fixed = fix_titles(text, name)
        if fixed.count('"pointer-events"') != text.count('"pointer-events"') + 1:
            sys.exit(f"FATAL: {name}: the edit did not add exactly one pointer-events")
        dst = os.path.join(out_root, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(fixed)
        print(f"    {name}: titles group takes no pointer input")


if __name__ == "__main__":
    main()
