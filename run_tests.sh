#!/bin/bash
# run_tests.sh
# ChromaGlow — Pre-release test runner
# Run this before every git tag/release. Exit code: 0 = all pass, 1 = failure.
#
# Usage:
#   ./run_tests.sh              # auto-selects booted simulator or first available
#   ./run_tests.sh --device     # runs on connected physical device (requires trusted device)

set -euo pipefail

PROJECT="ChromaGlow.xcodeproj"
SCHEME="ChromaGlow"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ChromaGlow — Pre-Release Test Suite"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ──────────────────────────────────────────────
# Destination selection
# ──────────────────────────────────────────────

DEVICE_ID="00008150-001575083E52401C"
DEVICE_NAME="brian's iPhone"
DESTINATION="platform=iOS,id=$DEVICE_ID"
echo "📱 Running on: $DEVICE_NAME ($DEVICE_ID)"
echo ""

# ──────────────────────────────────────────────
# Build app first
# ──────────────────────────────────────────────

echo "🔨 Building ChromaGlow..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -destination "$DESTINATION" \
  -quiet \
  || { echo "❌  Build FAILED"; exit 1; }

echo "✅ Build succeeded."
echo ""

# ──────────────────────────────────────────────
# Run tests
# ──────────────────────────────────────────────

echo "🧪 Running all unit tests..."
RESULT=$(xcodebuild test \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -sdk iphoneos \
  -destination "$DESTINATION" \
  2>&1)

echo "$RESULT" | grep -E "Test Suite|passed|failed|error:" | grep -v "^note:" || true

if echo "$RESULT" | grep -q "** TEST FAILED **"; then
  echo ""
  echo "❌  TEST SUITE FAILED — do not tag a release."
  echo ""
  # Print failing tests
  echo "$RESULT" | grep -E "FAILED|error:" | grep -v "^note:" || true
  exit 1
elif echo "$RESULT" | grep -q "** TEST SUCCEEDED **"; then
  # Extract summary line
  SUMMARY=$(echo "$RESULT" | grep "Executed" | tail -1)
  echo ""
  echo "✅  $SUMMARY"
  echo "🎉 All tests passed — safe to tag release."
  echo ""
  exit 0
else
  echo ""
  echo "⚠️  Could not determine test result. Check output above."
  exit 1
fi
