#!/usr/bin/env bash
# verify_spotify_experiment_absent.sh — prove a built ChromaGlow .app carries
# NONE of the LOCAL-ONLY Spotify Connect PCM experiment (receiver code, FFI
# symbols, UI copy, Bonjour declaration). Run it against every Release /
# TestFlight / normal Debug product:
#   Scripts/verify_spotify_experiment_absent.sh path/to/HueHome.app
# Exit 0 = clean. Exit 1 = experiment found (do not ship). With --expect-present
# the logic inverts (sanity check against a Debug-SpotifyExperimental build).
set -euo pipefail

APP="${1:?usage: $0 path/to/HueHome.app [--expect-present]}"
EXPECT_PRESENT=0
[[ "${2:-}" == "--expect-present" ]] && EXPECT_PRESENT=1

# Experiment-only markers. (The pre-existing, separately dev-flagged Spotify
# Web API metadata source is NOT part of this experiment, so plain "Spotify"
# is deliberately not a marker.)
MARKERS=(
  "cg_spotify_start"
  "cg_spotify_read_playback"
  "librespot"
  "SpotifyPCMRouter"
  "SpotifyConnectReceiver"
  "SpotifyConnectExperimentSection"
  "Spotify Connect — Experimental"
  "ChromaGlow Sync"
  "_spotify-connect._tcp"
)

found=0
# Every Mach-O in the bundle (main binary, debug dylib, extensions, frameworks).
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then
    for m in "${MARKERS[@]}"; do
      if LC_ALL=C grep -a -F -q "$m" "$f"; then
        echo "FOUND \"$m\" in ${f#$APP/}"
        found=1
      fi
    done
  fi
done < <(find "$APP" -type f -print0)

for plist in "$APP/Info.plist"; do
  if /usr/libexec/PlistBuddy -c "Print :NSBonjourServices" "$plist" 2>/dev/null | grep -q "_spotify-connect._tcp"; then
    echo "FOUND _spotify-connect._tcp in Info.plist NSBonjourServices"
    found=1
  fi
done

if [[ $EXPECT_PRESENT == 1 ]]; then
  [[ $found == 1 ]] && { echo "OK: experiment present (as expected)"; exit 0; }
  echo "FAIL: expected the experiment in this build but found no marker"; exit 1
fi
[[ $found == 0 ]] && { echo "OK: no Spotify experiment code, UI or Bonjour declaration in $(basename "$APP")"; exit 0; }
echo "FAIL: the Spotify experiment is present — this build must not be distributed"
exit 1
