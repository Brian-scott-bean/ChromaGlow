#!/bin/bash
# inject_spotify_experiment_plist.sh
# ChromaGlow — LOCAL-ONLY Spotify Connect PCM experiment
#
# Adds the experiment's Info.plist needs to the PROCESSED app-bundle
# Info.plist, and only in the Debug-SpotifyExperimental configuration. Every
# other configuration (Debug, Release, archives) exits here untouched. Never
# modifies HueHome/Info.plist (source) — same discipline as
# inject_build_metadata.sh.
#
#   NSBonjourServices += _spotify-connect._tcp   (advertise "ChromaGlow Sync")
#   UIBackgroundModes += audio                   (Phase 2: the received music
#                                                 keeps playing with the screen
#                                                 locked / another app open)

set -euo pipefail

if [[ "${CONFIGURATION:-}" != "Debug-SpotifyExperimental" ]]; then
    exit 0
fi

case " ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} " in
    *" CHROMAGLOW_EXPERIMENTAL_SPOTIFY "*) ;;
    *) echo "error: Debug-SpotifyExperimental is missing CHROMAGLOW_EXPERIMENTAL_SPOTIFY" >&2; exit 1 ;;
esac

plist="${CHROMAGLOW_EXPERIMENT_PLIST_PATH:-${TARGET_BUILD_DIR}/${INFOPLIST_PATH}}"
buddy=/usr/libexec/PlistBuddy

if ! "$buddy" -c "Print :NSBonjourServices" "$plist" >/dev/null 2>&1; then
    "$buddy" -c "Add :NSBonjourServices array" "$plist"
fi
if ! "$buddy" -c "Print :NSBonjourServices" "$plist" | grep -q "_spotify-connect._tcp"; then
    "$buddy" -c "Add :NSBonjourServices: string _spotify-connect._tcp" "$plist"
fi
if ! "$buddy" -c "Print :UIBackgroundModes" "$plist" >/dev/null 2>&1; then
    "$buddy" -c "Add :UIBackgroundModes array" "$plist"
fi
if ! "$buddy" -c "Print :UIBackgroundModes" "$plist" | grep -qx "[[:space:]]*audio"; then
    "$buddy" -c "Add :UIBackgroundModes: string audio" "$plist"
fi
echo "Spotify experiment: NSBonjourServices includes _spotify-connect._tcp; UIBackgroundModes includes audio"
