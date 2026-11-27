#!/usr/bin/env bash
# gen-version-header.sh — emit build/ios-gen/openq4_version_generated.h as a
# PURE FUNCTION OF UPSTREAM.pin (DECISIONS D-066).
#
#   scripts/gen-version-header.sh [--print-hash]
#
# Why this exists. Upstream's tools/build/openq4_version.py derives
# OPENQ4_VERSION_RESOURCE_BUILD from `git rev-list --count HEAD` of its
# --source-root. Our source root is build/src-ios, which is not a git repo, so
# git walks up and counts OUR repository — the number therefore rose with every
# commit we made. That number is the game modules' BUILD_NUMBER
# (src/framework/BuildVersion.h), and both savegame paths in
# game/gamesys/SaveGame.cpp refuse a payload whose build number differs from the
# running module's. So every commit invalidated every save, and any binary built
# at a different commit than the game modules disagreed with itself.
#
# The rule (D-066, revised by D-118): the resource build number is a function
# of the upstream pin and nothing else, identical for the engine and both game
# modules, and it does not move until UPSTREAM.pin moves.
#
# Until v0.14.000 it was a hash of the pinned commit pair (1..65535). From
# v0.14.1 upstream reads a save's LAYOUT by its build number
# (src/framework/SaveGameReleases.h: fields and GUI revisions added at build N
# are read only from payloads stamped >= N), so the number must be what a full
# upstream checkout stamps: the commit count of the pinned commit. That is
# recorded as OPENQ4_BUILD in UPSTREAM.pin by bump-pin.sh (it needs history the
# --depth 1 vendor clone does not have). The two hash stamps that shipped
# (28284, 41192) are mapped back to real builds by overlay patch 0031.
#
# The header is written only when its contents change, so an unchanged pin
# leaves the mtime alone and the staleness checks in build-ios-app.sh /
# publish-ota.sh stay meaningful.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TREE="$ROOT/build/src-ios"
VENDOR="$ROOT/vendor/openQ4"
GEN="$ROOT/build/ios-gen"
PIN="$ROOT/UPSTREAM.pin"
HEADER="$GEN/openq4_version_generated.h"

PRINT_HASH=0
[ "${1:-}" = "--print-hash" ] && PRINT_HASH=1

[ -f "$PIN" ] || { echo "FATAL: missing $PIN" >&2; exit 1; }
[ -x "$TREE/tools/build/openq4_version.py" ] || [ -f "$TREE/tools/build/openq4_version.py" ] \
	|| { echo "FATAL: run scripts/sync-overlay.sh first (no $TREE/tools)" >&2; exit 1; }

ENGINE_COMMIT="$(sed -n 's/^OPENQ4_COMMIT=//p' "$PIN" | head -1)"
GAME_COMMIT="$(sed -n 's/^OPENQ4_GAME_COMMIT=//p' "$PIN" | head -1)"
[ -n "$ENGINE_COMMIT" ] && [ -n "$GAME_COMMIT" ] \
	|| { echo "FATAL: could not read the commit pair out of $PIN" >&2; exit 1; }

RESOURCE_BUILD="$(sed -n 's/^OPENQ4_BUILD=//p' "$PIN" | head -1)"
[[ "$RESOURCE_BUILD" =~ ^[0-9]+$ ]] && [ "$RESOURCE_BUILD" -le 65535 ] \
	|| { echo "FATAL: UPSTREAM.pin has no valid OPENQ4_BUILD (the pinned commit's upstream commit count, written by bump-pin.sh; D-118)" >&2; exit 1; }

# D-110: from v0.13.2 the build number is part of savegame acceptance. The
# engine refuses any v3 save whose payload build is below
# SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD (upstream's build numbers are
# commit counts, so the floor is "older than the first verified decoder"), and
# the game modules special-case INITIAL_RELEASE_BUILD_NUMBER (retail 1262). Our
# number is a hash of the pin, not a count, so it could land on either by
# chance — and then this build would refuse its OWN saves. Fail loudly instead.
# (Since D-118 it is the real commit count, so this guards a bad pin file.)
SAVE_FLOOR="$(sed -n 's/^static const int SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD = \([0-9][0-9]*\);.*/\1/p' \
	"$VENDOR/src/framework/Session.cpp" | head -1)"
[ -n "$SAVE_FLOOR" ] || { echo "FATAL: no SESSION_OPENQ4_SAVEGAME_MINIMUM_SUPPORTED_BUILD in vendor/openQ4 Session.cpp — re-check D-110's build-number rule" >&2; exit 1; }
RETAIL_BUILD="$(sed -n 's/^const int INITIAL_RELEASE_BUILD_NUMBER = \([0-9][0-9]*\);.*/\1/p' \
	"$VENDOR/src/game/gamesys/SaveGame.h" | head -1)"
[ -n "$RETAIL_BUILD" ] || { echo "FATAL: no INITIAL_RELEASE_BUILD_NUMBER in vendor/openQ4/src/game SaveGame.h" >&2; exit 1; }
[ "$RESOURCE_BUILD" -ge "$SAVE_FLOOR" ] && [ "$RESOURCE_BUILD" -ne "$RETAIL_BUILD" ] || {
	echo "FATAL: pin-derived build number $RESOURCE_BUILD is below upstream's savegame floor $SAVE_FLOOR" >&2
	echo "       (or equals the retail build $RETAIL_BUILD): this build would refuse its own saves." >&2
	echo "       Decide a new derivation in DECISIONS.md before shipping this pin (D-066, D-110)." >&2
	exit 1; }

mkdir -p "$GEN"
# Since v0.15.0 upstream writes TWO headers: openq4_version_generated.h (the
# release version, stable across commits) and openq4_build_id_generated.h (git
# SHA, dirty flag, commit count, date — the fields we overwrite below). Both are
# generated into one temp dir (the build-id header includes the other) and
# replaced only when their contents change.
TMPD="$GEN/.version-tmp"
rm -rf "$TMPD"; mkdir -p "$TMPD"
TMPV="$TMPD/openq4_version_generated.h"
TMP="$TMPD/openq4_build_id_generated.h"
BIDHEADER="$GEN/openq4_build_id_generated.h"

# Upstream's generator still owns the headers' SHAPE (field set, ordering,
# base-version parsing out of meson.build) so a pin bump that adds a field is
# picked up rather than silently dropped. We run it against vendor/openQ4 so the
# git metadata it embeds describes the PIN and not our working tree, then
# overwrite the git-derived fields with the pin-derived values.
python3 "$TREE/tools/build/openq4_version.py" \
	--source-root "$VENDOR" --track dev --header-out "$TMPV" --build-id-header-out "$TMP" > /dev/null \
	|| { echo "FATAL: version header generation failed" >&2; exit 1; }
[ -s "$TMPV" ] && [ -s "$TMP" ] || { echo "FATAL: upstream generator did not write both headers" >&2; exit 1; }

SHORT_SHA="${ENGINE_COMMIT:0:8}"
MAJOR="$(sed -n 's/^#define OPENQ4_VERSION_MAJOR //p' "$TMPV")"
MINOR="$(sed -n 's/^#define OPENQ4_VERSION_MINOR //p' "$TMPV")"
PATCHV="$(sed -n 's/^#define OPENQ4_VERSION_PATCH //p' "$TMPV")"
[ -n "$MAJOR" ] && [ -n "$MINOR" ] && [ -n "$PATCHV" ] \
	|| { echo "FATAL: upstream header has no MAJOR/MINOR/PATCH — did the generator change?" >&2; exit 1; }

# Ground rule 3: every scripted edit asserts its match count.
subst() { # <sed expression> <expected match count> <grep pattern>
	local expr="$1" want="$2" got
	got="$(grep -c "$3" "$TMP" || true)"
	[ "$got" = "$want" ] || { echo "FATAL: expected $want match(es) for '$3' in the generated build-id header, got $got" >&2; exit 1; }
	sed -i '' "$expr" "$TMP"
}

subst "s/^#define OPENQ4_VERSION_RESOURCE_BUILD .*/#define OPENQ4_VERSION_RESOURCE_BUILD ${RESOURCE_BUILD}/" 1 '^#define OPENQ4_VERSION_RESOURCE_BUILD '
subst "s/^#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING .*/#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING \"${MAJOR}, ${MINOR}, ${PATCHV}, ${RESOURCE_BUILD}\"/" 1 '^#define OPENQ4_VERSION_RESOURCE_COMMAS_STRING '
subst "s/^#define OPENQ4_VERSION_RESOURCE_DOTTED .*/#define OPENQ4_VERSION_RESOURCE_DOTTED \"${MAJOR}.${MINOR}.${PATCHV}.${RESOURCE_BUILD}\"/" 1 '^#define OPENQ4_VERSION_RESOURCE_DOTTED '
subst "s/^#define OPENQ4_VERSION_GIT_SHA .*/#define OPENQ4_VERSION_GIT_SHA \"${SHORT_SHA}\"/" 1 '^#define OPENQ4_VERSION_GIT_SHA '
subst "s/^#define OPENQ4_VERSION_GIT_DIRTY .*/#define OPENQ4_VERSION_GIT_DIRTY 0/" 1 '^#define OPENQ4_VERSION_GIT_DIRTY '
subst "s/^#define OPENQ4_VERSION_COMMIT_COUNT .*/#define OPENQ4_VERSION_COMMIT_COUNT ${RESOURCE_BUILD}/" 1 '^#define OPENQ4_VERSION_COMMIT_COUNT '

# The version STRINGS also carry git metadata (+g<sha>[.dirty]); vendor/openQ4 is
# a clean shallow clone at the pin, so they already name the pinned commit. Assert
# it rather than trust it — a dirty vendor tree would leak ".dirty" into the
# shipped banner and make the build irreproducible.
grep -q "^#define OPENQ4_VERSION \".*g${SHORT_SHA}\"\$" "$TMP" || {
	echo "FATAL: generated OPENQ4_VERSION does not end at the pinned sha g${SHORT_SHA}:" >&2
	grep '^#define OPENQ4_VERSION ' "$TMP" >&2
	echo "       (is vendor/openQ4 dirty or at the wrong commit? re-run scripts/sync-overlay.sh)" >&2
	exit 1
}

for pair in "$TMPV:$HEADER" "$TMP:$BIDHEADER"; do
	src="${pair%%:*}"; dst="${pair#*:}"
	if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
		rm -f "$src"
	else
		mv "$src" "$dst"
	fi
done
rm -rf "$TMPD"

HASH="$(cat "$HEADER" "$BIDHEADER" | shasum -a 256 | awk '{print $1}')"
if [ "$PRINT_HASH" = 1 ]; then
	echo "$HASH"
else
	echo "    openq4_version_generated.h + openq4_build_id_generated.h  build ${RESOURCE_BUILD} (pin ${SHORT_SHA})  sha256 ${HASH:0:12}"
fi
