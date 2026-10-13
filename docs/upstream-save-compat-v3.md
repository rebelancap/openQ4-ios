# Upstream drafts: format-3 single-player saves do not load on v0.14.000

Drafts only — NOT filed. Written 2026-10-13 from the openQ4-ios v0.14 bump
(D-116). Evidence paths are in this repo; attach the oracle log and the three
fixture saves (work/fmt3save/, retail-derived, so share privately or ask the
maintainer to reproduce with their own v0.13.2 build).

---

## Issue draft

**Title:** Single-player saves from v0.13.x (payload v3) fail to load on v0.14.000: `idWinStr::ReadFromSaveGame: invalid string length`

**Summary.** v0.14.000 writes save payload v4 and still accepts v3
(`SESSION_OPENQ4_SAVEGAME_PREVIOUS_COMPATIBILITY_VERSION`), and every new
game-side field is gated on `GetOpenQ4SaveGameCompatibilityVersion() >= 4`, so
v3 saves are meant to load. They don't: every v3 single-player save we tried
fails mid-restore and the engine drops back to the main menu.

**Repro (macOS arm64, stock v0.14.000 1621aa21, retail 1.4.2 q4base):**
1. With a v0.13.2 (fcdd5696 + openQ4-game 8f411dbc) build, start
   `map game/airdefense1` (or `game/hangar1`, or `game/dispersal` for the Strogg
   HUD), wait until play starts, `savegame test`.
2. Copy `baseoq4/savegames/test.*` into a v0.14.000 home and `loadgame test`.

**Result:** the map loads, then
```
ERROR: idWinStr::ReadFromSaveGame: invalid string length 4194304 at offset 444350 (remaining 8035464)
```
and the menu comes back. 3 of 3 saves fail the same way (airdefense1 /
hangar1 marine HUD at offsets 444350 / 464466; dispersal Strogg HUD at 564032).

**Cause.** `content/baseoq4/pak0/guis/hud.gui` and `guis/hud_strogg.gui` gained
a new `windowDef hit_indicator_reduced` (and an extra `set "matcolor"` in
`hit_indicator`'s `onTime 0`) for `ui_reducedFlashing` between v0.13.2 and
v0.14.000. The player HUD is saved with the game
(`idPlayer::Save` → `WriteUserInterface( hud )`), and
`idWindow::WriteToSaveGame` / `ReadFromSaveGame` serialise the desktop's window
tree field by field with no length prefix or per-window framing. The restore
walks the CURRENT tree, so any shape change to a saved GUI desyncs the stream;
the first string read after the divergence picks up garbage. `idWindow`'s
child-id / name checks would catch it a few windows later, but `idWinStr`
trips first. The window save code itself is unchanged between the tags (apart
from the Remastered peer removal), so this is purely content drift.

**Impact.** Every v0.13.x campaign save, on every platform. The game-side
compatibility work for v3 is correct but unreachable for SP saves.

**Suggested fixes:** see the PR draft below (load-time compatibility for v3),
and longer term frame GUI blobs in the next payload version.

---

## PR draft

**Title:** Restore v3 saves whose HUD GUI changed shape (legacy GUI shapes for older payloads)

**What.** When restoring a payload older than N, a saved GUI whose file has
changed shape since payload N-1 is read through the GUI file that wrote it:

- a small table `{ gui, belowPayload, legacyFile }` — today two entries,
  `guis/hud.gui` and `guis/hud_strogg.gui`, `belowPayload 4`, legacy files the
  v0.13.2 versions shipped under `guis/savecompat/payload3/` (unmodified copies
  of the v0.13.2 pak0 files);
- `idUserInterfaceLocal::ReadFromSaveGame` reads the state dict and flags as
  today; then, if the table names a legacy file for this GUI and payload, it
  parses that file into a throwaway unmanaged `idUserInterfaceLocal`, hands it
  the restored state dict, and lets its desktop consume the blob exactly. The
  live GUI is re-initialised from its current file (`InitFromFile`, the same
  in-place reload `reloadGuis` uses — cached GUIs can still carry a previous
  level's window state) and gets the saved dict and flags back;
- the session hands the validated payload version to the UI around the game
  restore (`UI_SetSaveGameRestorePayloadVersion`), cleared afterwards and on
  the exception path.
- `ui_legacySaveShapes 0` disables it (reads against the current file, as
  before) — a kill switch and a way to reproduce the bug.

**What is lost** for a v3 save: in-flight HUD transitions and window-local
script state (e.g. a hit-indicator fade that was mid-flight). The gui:: state
dict — every value the game and scripts publish to the HUD — is kept, and the
player's HUD repaints from player state on the next frame. Everything else in
the save (entities, player position, inventory, scripts) restores normally.

**Tested** (openQ4-ios, iOS simulator, v0.14.000 + this change): three v3
saves made by v0.13.2 (airdefense1, hangar1 — marine HUD; dispersal — Strogg
HUD) load at exactly the `getviewpos` the v0.13.2 build reports for them
(`(10325.03 -6962.78 6.95) -105.0`, `(-5256 2864 -5819.75) 0.0`,
`(3120 -5144 -1467.75) 90.0`), same health and weapon. A save written after
such a load (v4) reloads normally. With `ui_legacySaveShapes 0` the original
`idWinStr` error reappears. Log line on success:
`GUI save restore: guis/hud.gui from payload 3 read through guis/savecompat/payload3/hud.gui (105618 bytes); window-local state reset`.

**Notes for review**
- The legacy files must ship somewhere the VFS sees them but no stock path
  uses; pak0 is fine upstream (our port ships them loose because our pak0 MD5
  is generated by the build).
- Rule for the future: any change to a GUI that `WriteUserInterface` saves
  (player HUDs, objective/cinematic HUDs, cursor/focus GUIs, weapon zoom GUIs,
  vehicle HUDs) needs either a payload bump plus a table entry, or must not
  change the window tree / script parm count.

**Better long-term fix (follow-up, needs a payload bump):** length-prefix each
saved GUI blob (and ideally each window: name + byte length) in
`idSaveGame::WriteUserInterface`. A reader can then skip a blob whose tree no
longer matches, keep the state dict, and re-init the GUI — no legacy files, no
table, and HUD content edits stop being save-breaking. Older payloads would
still need the shape table above.
