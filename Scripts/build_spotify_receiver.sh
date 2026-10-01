#!/usr/bin/env bash
# build_spotify_receiver.sh — LOCAL-ONLY Spotify Connect experiment.
#
# Builds the Rust receiver (Experimental/SpotifyReceiver, pinned librespot) as
# static libraries for the iOS device and simulator, where the
# "Debug-SpotifyExperimental" build configuration links them from:
#   Experimental/SpotifyReceiver/build/iphoneos/libchromaglow_spotify.a
#   Experimental/SpotifyReceiver/build/iphonesimulator/libchromaglow_spotify.a
# plus an XCFramework bundling both (convenience; Xcode links the .a files).
#
# Outputs are git-ignored. Normal Debug/Release builds never need them.
# Usage: Scripts/build_spotify_receiver.sh [--debug] [--skip-tests]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CRATE="$ROOT/Experimental/SpotifyReceiver"
OUT="$CRATE/build"
PROFILE=release
CARGO_PROFILE_FLAG=--release
RUN_TESTS=1
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE=debug; CARGO_PROFILE_FLAG= ;;
    --skip-tests) RUN_TESTS=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

export PATH="$HOME/.cargo/bin:$PATH"
command -v cargo >/dev/null || { echo "cargo not found — install Rust: https://rustup.rs (see docs/ios/local-spotify-pcm-experiment.md)" >&2; exit 1; }
for t in aarch64-apple-ios aarch64-apple-ios-sim; do
  rustup target list --installed | grep -qx "$t" || rustup target add "$t"
done

# Match the app's deployment target so the linker doesn't warn per object.
export IPHONEOS_DEPLOYMENT_TARGET=17.0

cd "$CRATE"
if [ "$RUN_TESTS" = 1 ]; then
  cargo test --locked --lib
fi
cargo rustc --locked $CARGO_PROFILE_FLAG --lib --crate-type staticlib --target aarch64-apple-ios
cargo rustc --locked $CARGO_PROFILE_FLAG --lib --crate-type staticlib --target aarch64-apple-ios-sim

rm -rf "$OUT"
mkdir -p "$OUT/iphoneos" "$OUT/iphonesimulator"
cp "target/aarch64-apple-ios/$PROFILE/libchromaglow_spotify.a" "$OUT/iphoneos/"
cp "target/aarch64-apple-ios-sim/$PROFILE/libchromaglow_spotify.a" "$OUT/iphonesimulator/"

xcodebuild -create-xcframework \
  -library "$OUT/iphoneos/libchromaglow_spotify.a" -headers "$CRATE/include" \
  -library "$OUT/iphonesimulator/libchromaglow_spotify.a" -headers "$CRATE/include" \
  -output "$OUT/ChromaGlowSpotify.xcframework" >/dev/null

echo "Built ($PROFILE) — librespot $(grep -m1 '^rev = ' Cargo.toml | cut -d'"' -f2)"
ls -la "$OUT/iphoneos" "$OUT/iphonesimulator"
