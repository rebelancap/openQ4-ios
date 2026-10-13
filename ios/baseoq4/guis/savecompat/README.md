# Legacy GUI shapes for older saves (D-116)

`payload3/hud.gui` and `payload3/hud_strogg.gui` are openQ4 **v0.13.2**'s
`content/baseoq4/pak0/guis/hud.gui` and `hud_strogg.gui`, unmodified (GPLv3,
upstream openQ4 content). Those were the HUDs in every save made by
openQ4-ios 1.0.0 (save payload v3, build 28284). v0.14.000 added
`windowDef hit_indicator_reduced` to both, so their v3 save blobs no longer
parse against the current files; the engine reads them through these instead
(`ui_legacySaveShapes`, overlay patch 0030).

Provenance, checked 2026-10-13: extracted from `baseoq4/pak0.pk4` inside the
published 1.0.0 IPA (`ota/openq4/openq4-ios.ipa`, CFBundleVersion
10000.0.28284 — our own build of v0.13.2 pak0), and byte-identical to
`git show v0.13.2:content/baseoq4/pak0/guis/<file>` in vendor/openQ4.

| file | sha256 |
|---|---|
| hud.gui | a18f8551d4a83fe2ef100d72f1e270058e9c32e33fd0b0c5174771d23e782989 |
| hud_strogg.gui | 73b58d4b46b974379542fd663a0f43c75f01846161a0ffc60c3056b090ed9b23 |

`stage-bundle-content.sh` copies them to `<app>/baseoq4/guis/savecompat/`.
