#!/usr/bin/env bash
# sync-overlay.sh — rebuild the iOS build tree from pristine vendor + our patches.
#
#   build/src-ios/                     =  vendor/openQ4  + overlay/patches/*.patch
#   build/src-ios/src/{game,mpgame}    =  (same tree)     + overlay/patches-game/*.patch
#
# Since v0.14.000 the game sources are in-tree upstream (D-116); before that
# they came from a second repo, openQ4-game, staged by stage_gamelibs.py into
# .tmp/gamelibs_stage. The game patches stay a separate set: they patch
# SDK-EULA code, not GPL code, and that split is worth keeping visible.
#
# Charter ground rule 1: upstream stays pristine, every local change is a
# reviewable patch, and a patch that fails to apply fails the build loudly.
# Nothing is ever hand-edited under vendor/.
#
# Two details that are deliberate, both learned the hard way in sibling ports:
#
#   rsync -rlpc --delete   — checksum-based (-c), and NOT -t. Preserving mtimes
#                            lets a build system silently reuse a stale object
#                            after a patch changes a file, producing a false A/B
#                            that costs a day to find.
#   patch --fuzz=0         — a patch that no longer applies exactly is a patch
#                            that must be re-reviewed against new upstream, not
#                            fuzzily re-aimed.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/vendor/openQ4"
TREE="$ROOT/build/src-ios"
GEN="$ROOT/build/ios-gen"
PATCHES="$ROOT/overlay/patches"
PATCHES_GAME="$ROOT/overlay/patches-game"

[ -d "$VENDOR" ]      || { echo "FATAL: missing $VENDOR" >&2; exit 1; }

mkdir -p "$TREE" "$GEN"

# content/ is 2.3 GB of pak *source data* (baked light grids, loadscreens). No
# patch will ever touch it and the engine compile does not read it, so it is
# excluded to keep this sync fast. The pak build reads it from vendor/ directly.
echo "==> syncing vendor/openQ4 -> build/src-ios"
rsync -rlpc --delete \
	--exclude '.git/' \
	--exclude 'content/' \
	--exclude 'builddir/' \
	--exclude '.tmp/' \
	"$VENDOR/" "$TREE/"

echo "==> applying overlay patches"
shopt -s nullglob
applied=0
for p in "$PATCHES"/*.patch; do
	name="$(basename "$p")"
	if patch -p1 -d "$TREE" --fuzz=0 --forward --silent < "$p"; then
		echo "    applied $name"
		applied=$((applied + 1))
	else
		echo "FATAL: patch failed to apply: $name" >&2
		echo "       (upstream moved? re-review against the new pin, do not re-aim with fuzz)" >&2
		exit 1
	fi
done
shopt -u nullglob
echo "    $applied patch(es) applied"

[ -f "$TREE/src/game/Game_local.cpp" ] && [ -f "$TREE/src/mpgame/Game_local.cpp" ] \
	|| { echo "FATAL: no in-tree game sources in the pin (src/game, src/mpgame) — see D-116" >&2; exit 1; }
# A stage from a pre-v0.14 pin would only confuse a reader; nothing uses it.
rm -rf "$TREE/.tmp/gamelibs_stage"

# The game sources get exactly the engine's discipline (D-070): a change to
# idPlayer::UpdateFocus is a reviewable patch, applied here with --fuzz=0,
# failing loudly on a pin bump — never a hand edit under vendor/. They are
# applied AFTER the engine overlay, to the same tree, and regen-patches.sh keeps
# src/game and src/mpgame out of the engine patch set.
echo "==> applying game overlay patches"
shopt -s nullglob
gapplied=0
for p in "$PATCHES_GAME"/*.patch; do
	name="$(basename "$p")"
	if patch -p1 -d "$TREE" --fuzz=0 --forward --silent < "$p"; then
		echo "    applied $name"
		gapplied=$((gapplied + 1))
	else
		echo "FATAL: game patch failed to apply: $name" >&2
		echo "       (upstream game code moved? re-review against the new pin, do not re-aim with fuzz)" >&2
		exit 1
	fi
done
shopt -u nullglob
echo "    $gapplied game patch(es) applied"

# The client links, since v0.14.000 (D-116), a retained-UI runtime that needs
# three of upstream's meson wrap-file subprojects, and the Vulkan renderer links
# glslang for in-process material shader compilation. Staged OUTSIDE the synced tree
# (the rsync above would delete them) from the pinned tree's own wrap files and
# packagefiles, hash-verified, diffs applied at --fuzz=0; a stamp keeps an
# unchanged pin from re-staging (and so from touching mtimes).
echo "==> staging wrap subprojects (RmlUi, JsonCpp, libtess2, glslang)"
python3 "$ROOT/scripts/stage-wrap-subprojects.py" "$TREE" "$ROOT/build/ios-subprojects" "$ROOT/build/wrap-cache" \
	rmlui jsoncpp libtess2 glslang \
	|| { echo "FATAL: wrap subproject staging failed" >&2; exit 1; }

# openq4_version_generated.h is normally emitted by meson at configure time.
# We are not using meson for iOS, so generate it ourselves into build/ios-gen —
# and deterministically FROM THE PIN, never from git history (D-066): the
# resource build number in this header is the game modules' BUILD_NUMBER, and a
# number that moved with our own commit count invalidated every savegame.
echo "==> generating version header"
"$ROOT/scripts/gen-version-header.sh"
[ -f "$GEN/openq4_version_generated.h" ] \
	|| { echo "FATAL: version header not generated" >&2; exit 1; }

# openq4_savegame_compat_generated.h — the savegame fingerprint, generated HERE
# and not by build-ios-game-modules.sh, for two reasons (D-084):
#
#  - Ordering. framework/Session.cpp picks the header up with __has_include, so
#    on a clean tree an engine built before the game modules compiled with the
#    stamp check DISABLED (file count -1) while the modules enforced theirs. The
#    header now exists before anything compiles.
#  - Provenance. It is computed from pristine vendor/openQ4 (game sources in-tree)
#    at the pin, never from the patched trees this script just produced, and it
#    is asserted against overlay/savegame-stamp.txt.
echo "==> generating savegame compatibility header"
"$ROOT/scripts/gen-savegame-compat-header.sh"
[ -f "$GEN/openq4_savegame_compat_generated.h" ] \
	|| { echo "FATAL: savegame compat header not generated" >&2; exit 1; }

# openq4_paks_generated.h embeds the MD5s of the baseoq4 runtime packs, which
# the engine verifies at startup and hard-fatals on mismatch. Meson normally
# generates it from the packs it just built.
#
# We borrow the oracle's built packs: they come from the same pinned content
# tree, so the checksums are identical to what an untrimmed iOS pack build would
# produce. That coupling is temporary — once the iOS pack build exists (and with
# it the charter's pak1 trim decision), it generates this header itself, and a
# trimmed pack REQUIRES regenerating it or the engine will refuse to start.
# Which packs: scripts/paks.sh is the one answer every script shares (D-113) —
# the oracle's meson output on the original dev machine, build/baseoq4 from
# scripts/build-baseoq4-paks.sh everywhere else, or an explicit $OPENQ4_PAKS_DIR.
. "$ROOT/scripts/paks.sh"
PAKS_DIR="$(openq4_paks_dir)"
PAKS_SOURCE="$(openq4_paks_source)"
echo "==> generating pak checksum header (packs: $PAKS_SOURCE, $PAKS_DIR)"
# The packs must come from the PINNED content tree (D-110). Packs left at an
# older pin would hand us self-consistent checksums for the wrong pak0 — the
# engine would boot, with last pin's GUIs, strings and profiles. Refuse it.
PIN_COMMIT="$(sed -n 's/^OPENQ4_COMMIT=//p' "$ROOT/UPSTREAM.pin" | head -1)"
case "$PAKS_SOURCE" in
	oracle)
		ORACLE_COMMIT="$(git -C "$ROOT/work/oracle/openQ4" rev-parse HEAD 2>/dev/null || true)"
		[ -n "$PIN_COMMIT" ] && [ "$ORACLE_COMMIT" = "$PIN_COMMIT" ] || {
			echo "FATAL: the oracle tree is at ${ORACLE_COMMIT:-<none>}, UPSTREAM.pin says $PIN_COMMIT" >&2
			echo "       its packs are stale for this pin — run scripts/bump-pin.sh (it moves and rebuilds the oracle)" >&2
			exit 1; }
		for f in pak0.pk4 pak1.pk4; do
			[ "$PAKS_DIR/$f" -nt "$ROOT/work/oracle/openQ4/.git/HEAD" ] || {
				echo "FATAL: $PAKS_DIR/$f predates the oracle's last checkout — rebuild the oracle (meson compile -C work/oracle/openQ4/builddir)" >&2
				exit 1; }
		done ;;
	vendor)
		[ -f "$PAKS_DIR/.pin-commit" ] && [ "$(cat "$PAKS_DIR/.pin-commit")" = "$PIN_COMMIT" ] || {
			echo "FATAL: no baseoq4 packs for pin ${PIN_COMMIT:0:8} in $PAKS_DIR" >&2
			echo "       run scripts/build-baseoq4-paks.sh" >&2
			exit 1; } ;;
	explicit)
		echo "!!  OPENQ4_PAKS_DIR is set: using $PAKS_DIR without a pin check" >&2 ;;
esac
ORACLE_PAKS="$PAKS_DIR"
if [ -f "$ORACLE_PAKS/pak0.pk4" ] && [ -f "$ORACLE_PAKS/pak1.pk4" ]; then
	python3 "$TREE/tools/build/generate_pak_header.py" \
		--pak0 "$ORACLE_PAKS/pak0.pk4" --pak1 "$ORACLE_PAKS/pak1.pk4" \
		--header-out "$GEN/openq4_paks_generated.h" > /dev/null
	[ -f "$GEN/openq4_paks_generated.h" ] || { echo "FATAL: pak header not generated" >&2; exit 1; }
else
	echo "FATAL: no built baseoq4 packs at $ORACLE_PAKS" >&2
	echo "       run scripts/build-baseoq4-paks.sh (or build the macOS oracle)" >&2
	exit 1
fi

echo
echo "OVERLAY OK"
echo "  tree : $TREE"
echo "  gen  : $GEN"
