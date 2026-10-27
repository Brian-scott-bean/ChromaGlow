#!/bin/zsh
# Beat lab — today's mic tempo pipeline (compiled from the app's own, unmodified
# Core/Audio files) against the proposed tracker, on deterministic synthetic
# room audio. Nothing here is part of the app target; docs/ is not compiled.
#
#   docs/ios/play-along/beatlab/run.sh            # the full comparison table
#   docs/ios/play-along/beatlab/run.sh -service   # music-service drive vs mic phase
#   docs/ios/play-along/beatlab/run.sh -bar       # downbeat cue debug
#   docs/ios/play-along/beatlab/run.sh -cpu       # CPU per second of audio
#   docs/ios/play-along/beatlab/run.sh -onset     # how late a sound punch starts (tap vs hops)
set -euo pipefail
HERE=${0:a:h}
REPO=${HERE:h:h:h:h}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
xcrun swiftc -O -swift-version 5 -o "$OUT/beatlab" "$HERE"/*.swift \
  "$REPO/HueHome/Core/Audio/AudioSpectrumProcessor.swift" \
  "$REPO/HueHome/Core/Audio/AudioFeatureExtractor.swift" \
  "$REPO/HueHome/Core/Audio/TempoEstimator.swift" \
  "$REPO/HueHome/Core/Audio/BeatClock.swift" \
  "$REPO/HueHome/Core/Audio/OnsetFrameAnalyzer.swift" \
  "$REPO/HueHome/Core/Audio/BeatTracker.swift" \
  "$REPO/HueHome/Core/Music/MusicSource.swift"
"$OUT/beatlab" "$@"
