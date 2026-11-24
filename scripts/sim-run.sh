#!/usr/bin/env bash
# Build Halo for the iOS Simulator and launch it with a demo video as the lens camera.
#
# Usage: ./scripts/sim-run.sh [--grant] [video] [photos...]
#   video     a local video file played through the live lens (looped). Your own clip; it is read
#             in place, never copied into the app or the repo. Without it the lens shows a banner.
#   photos    optional images added to the Simulator's Photos library, for the on-device scan.
#   --grant   pre-grant Photos, Contacts, Camera and Microphone access, skipping those prompts.
#
# Environment:
#   HALO_SIM_DEVICE   simulator name or UDID (default: a booted iPhone, else the newest iPhone).
#
# Walkthrough: e2e/simulator.md.
set -euo pipefail

BUNDLE_ID="study.paradigm.halo"

GRANT=0
if [ "${1:-}" = "--grant" ]; then GRANT=1; shift; fi
VIDEO="${1:-}"
[ $# -gt 0 ] && shift

abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd -P)" "$(basename "$1")"); }

# Resolve every path against the caller's directory before moving to the repo root.
if [ -n "$VIDEO" ]; then
  [ -f "$VIDEO" ] && [ -r "$VIDEO" ] || { echo "error: video not found or unreadable: $VIDEO" >&2; exit 1; }
  VIDEO="$(abspath "$VIDEO")"
fi
PHOTOS=()
for photo in "$@"; do
  [ -f "$photo" ] || { echo "error: photo not found: $photo" >&2; exit 1; }
  PHOTOS+=("$(abspath "$photo")")
done

cd "$(dirname "$0")/.."
DERIVED="${HALO_SIM_DERIVED:-.build/sim-derived}"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Halo.app"

[[ "$(xcode-select -p 2>/dev/null)" == *.app/* ]] || { echo "error: Xcode is required" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "error: install xcodegen: brew install xcodegen" >&2; exit 1; }

if [ ! -d Models/HaloFaceEmbedder.mlmodelc ]; then
  echo "warning: Models/HaloFaceEmbedder.mlmodelc is missing: recognition will be unavailable."
  echo "         Run ./scripts/fetch-models.sh first to recognize people in the demo video."
fi

# --- Pick the simulator ----------------------------------------------------------------------
udid_for() {  # $1: exact name or UDID -> UDID of an available device (newest runtime wins)
  if [[ "$1" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    xcrun simctl list devices available | grep -Fio -- "$1" | head -1
    return
  fi
  # Exact name followed by " (", so "iPhone 17" never matches "iPhone 17 Pro". Runtimes are
  # listed oldest first: take the last match.
  xcrun simctl list devices available \
    | awk -v name="$1" '{ line = $0; sub(/^ +/, "", line); if (index(line, name " (") == 1) print line }' \
    | grep -Eo '\([0-9A-F-]{36}\)' | tail -1 | tr -d '()'
}
if [ -n "${HALO_SIM_DEVICE:-}" ]; then
  UDID="$(udid_for "$HALO_SIM_DEVICE")"
  [ -n "$UDID" ] || { echo "error: no available simulator matches '$HALO_SIM_DEVICE'" >&2; exit 1; }
else
  UDID="$(xcrun simctl list devices available | grep -E '^ +iPhone .*\(Booted\)' \
    | grep -Eo '\([0-9A-F-]{36}\)' | head -1 | tr -d '()' || true)"
  if [ -z "$UDID" ]; then
    UDID="$(xcrun simctl list devices available | grep -E '^ +iPhone ' \
      | grep -Eo '\([0-9A-F-]{36}\)' | tail -1 | tr -d '()' || true)"
  fi
  [ -n "$UDID" ] || { echo "error: no iPhone simulator installed (Xcode > Settings > Components)" >&2; exit 1; }
fi
NAME="$(xcrun simctl list devices available | grep -F "$UDID" | sed -E 's/^ +(.*) \([0-9A-F-]{36}\).*/\1/')"
echo "== Simulator: $NAME ($UDID)"

# --- Build -------------------------------------------------------------------------------------
echo "== Generating the Xcode project"
xcodegen generate --spec App/project.yml --quiet
echo "== Building for the Simulator (unsigned, derived data in $DERIVED)"
xcodebuild -project App/Halo.xcodeproj -scheme Halo -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" \
  -quiet CODE_SIGNING_ALLOWED=NO build
[ -d "$APP" ] || { echo "error: build produced no app at $APP" >&2; exit 1; }

# --- Boot --------------------------------------------------------------------------------------
echo "== Booting"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
SIM_APP="$(xcode-select -p)/Applications/Simulator.app"
if [ -d "$SIM_APP" ]; then
  open "$SIM_APP" --args -CurrentDeviceUDID "$UDID" || true
else
  echo "note: Simulator.app not found. View the simulator from Xcode (open App/Halo.xcodeproj, pick"
  echo "      the booted iPhone) or rely on screenshots: xcrun simctl io $UDID screenshot shot.png"
fi

echo "== Enrolling Face ID"
xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged

if [ ${#PHOTOS[@]} -gt 0 ]; then
  echo "== Adding ${#PHOTOS[@]} photo(s) to the Simulator's library"
  xcrun simctl addmedia "$UDID" "${PHOTOS[@]}"
fi

# --- Install + launch --------------------------------------------------------------------------
echo "== Installing"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

if [ "$GRANT" = 1 ]; then
  echo "== Pre-granting Photos, Contacts, Camera, Microphone"
  for service in photos contacts camera microphone; do
    xcrun simctl privacy "$UDID" grant "$service" "$BUNDLE_ID" || true
  done
fi

echo "== Launching"
if [ -n "$VIDEO" ]; then
  echo "   demo video: $VIDEO"
  SIMCTL_CHILD_HALO_DEMO_VIDEO="$VIDEO" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
else
  echo "   no demo video: the lens will show the 'Simulator has no camera' banner"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
fi

cat <<EOF

Halo is running on $NAME.
Unlock (Face ID match):
  xcrun simctl spawn $UDID notifyutil -p com.apple.BiometricKit_Sim.pearl.match
  (or Simulator menu Features > Face ID > Matching Face)
Screenshot:
  xcrun simctl io $UDID screenshot halo.png
EOF
