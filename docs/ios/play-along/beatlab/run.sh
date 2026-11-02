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
#
# Real recordings (build 914; audio on the Dev drive, never in the repo — Corpus.swift):
#   docs/ios/play-along/beatlab/run.sh -import    # annotations + manifest from raw/<set>/
#   docs/ios/play-along/beatlab/run.sh -corpus    # the shipping tracker on real songs, clean and in rooms
#   docs/ios/play-along/beatlab/run.sh -drums     # kick/snare/hi-hat recall and precision
#   docs/ios/play-along/beatlab/run.sh -selftest  # the room convolution against a direct sum
#   docs/ios/play-along/beatlab/run.sh -drumtune  # build 915: search the drum lanes' settings
#   docs/ios/play-along/beatlab/run.sh -kickbass  # build 915: kick vs bass — level gate, decay confirmation, snare veto/hold
#   docs/ios/play-along/beatlab/run.sh -tracktune # build 915: search the tracker's smoothing and confidence
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
  "$REPO/HueHome/Core/Audio/DrumLanes.swift" \
  "$REPO/HueHome/Core/Audio/BeatTracker.swift" \
  "$REPO/HueHome/Core/Music/MusicSource.swift"
"$OUT/beatlab" "$@"
