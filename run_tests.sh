#!/bin/bash
# run_tests.sh
# ChromaGlow — Pre-release test runner
# Run this before every git tag/release. Exit code: 0 = all pass, 1 = failure.
#
# Usage:
#   ./run_tests.sh              # deterministic: preferred model at the highest installed OS,
#                               # then booted simulator, then first available iPhone simulator
#   ./run_tests.sh --device     # runs on connected physical device (requires trusted device)
#
# Overrides:
#   CHROMAGLOW_TEST_UDID=<udid>        pin an exact simulator for one run (not repo truth)
#   CHROMAGLOW_TEST_MODEL="iPhone 17"  change the preferred simulator model name
#
# Multiple simulators can share one model name across installed OS runtimes, so a bare
# `name=` destination is ambiguous — selection resolves model + highest OS to one UDID.
#
# Verdict discipline: the pass/fail decision rides xcodebuild's exit code plus
# the .xcresult bundle (xcresulttool) — never a grep over piped log output,
# which can drop the "TEST SUCCEEDED" line under load.

set -euo pipefail

PROJECT="HueHome.xcodeproj"
SCHEME="HueHome 1"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ChromaGlow — Pre-Release Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ──────────────────────────────────────────────
# Destination selection
# ──────────────────────────────────────────────

if [[ "${1:-}" == "--device" ]]; then
  DEVICE_ID="00008150-001575083E52401C"
  DEVICE_NAME="brian's iPhone"
  DESTINATION="platform=iOS,id=$DEVICE_ID"
  SDK_ARGS=(-sdk iphoneos)
  echo "📱 Running on: $DEVICE_NAME ($DEVICE_ID)"
else
  PREFERRED_MODEL="${CHROMAGLOW_TEST_MODEL:-iPhone 17 Pro}"
  if [[ -n "${CHROMAGLOW_TEST_UDID:-}" ]]; then
    UDID="$CHROMAGLOW_TEST_UDID"
    echo "📱 Running on pinned simulator (CHROMAGLOW_TEST_UDID): $UDID"
  else
    # Deterministic pick: exact preferred model name at the HIGHEST installed iOS runtime.
    UDID=$(xcrun simctl list devices available --json 2>/dev/null | python3 -c '
import json, re, sys
model = sys.argv[1]
data = json.load(sys.stdin)
best = None
for runtime, devices in data.get("devices", {}).items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    os_key = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        if d.get("name") == model and d.get("isAvailable"):
            if best is None or os_key > best[0]:
                best = (os_key, d["udid"])
if best:
    print(best[1])
' "$PREFERRED_MODEL" 2>/dev/null || true)
    if [[ -n "$UDID" ]]; then
      echo "📱 Running on: $PREFERRED_MODEL, highest installed OS ($UDID)"
    else
      UDID=$(xcrun simctl list devices booted 2>/dev/null | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
      if [[ -n "$UDID" ]]; then
        echo "📱 Running on booted simulator: $UDID"
      else
        UDID=$(xcrun simctl list devices available 2>/dev/null | grep 'iPhone' | grep -Eo '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)
        if [[ -z "$UDID" ]]; then
          echo "❌  No iPhone simulator available. Install one in Xcode, or use --device."
          exit 1
        fi
        echo "📱 Running on first available iPhone simulator: $UDID"
      fi
    fi
  fi
  DESTINATION="platform=iOS Simulator,id=$UDID"
  SDK_ARGS=()
fi
echo ""

# ──────────────────────────────────────────────
# Run tests (build happens as part of `test`)
# ──────────────────────────────────────────────

RESULT_BUNDLE="$(mktemp -d)/run_tests.xcresult"

echo "🧪 Running all unit tests..."
if xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  ${SDK_ARGS[@]+"${SDK_ARGS[@]}"} \
  -destination "$DESTINATION" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -quiet; then
  TEST_EXIT=0
else
  TEST_EXIT=$?
fi

echo ""
if [[ -d "$RESULT_BUNDLE" ]]; then
  echo "📊 Result bundle: $RESULT_BUNDLE"
  xcrun xcresulttool get test-results summary --path "$RESULT_BUNDLE" 2>/dev/null \
    || xcrun xcresulttool get --legacy --format json --path "$RESULT_BUNDLE" 2>/dev/null \
      | grep -Eo '"(testsCount|testsFailedCount)"[^,}]*' \
    || echo "⚠️  xcresulttool summary unavailable — trusting the exit code."
fi

echo ""
if [[ $TEST_EXIT -eq 0 ]]; then
  echo "✅  TEST SUITE PASSED — safe to tag release."
  exit 0
else
  echo "❌  TEST SUITE FAILED (xcodebuild exit $TEST_EXIT) — do not tag a release."
  echo "    Inspect: xcrun xcresulttool get test-results tests --path \"$RESULT_BUNDLE\""
  exit 1
fi
