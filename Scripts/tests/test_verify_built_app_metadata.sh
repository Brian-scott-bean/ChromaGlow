#!/bin/bash
# test_verify_built_app_metadata.sh
# ChromaGlow — IOS-OPS-001D lightweight fixture tests for verify_built_app_metadata.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VERIFY_SCRIPT="${REPO_ROOT}/Scripts/verify_built_app_metadata.sh"

if [[ ! -x "$VERIFY_SCRIPT" ]]; then
    chmod +x "$VERIFY_SCRIPT"
fi

TESTS_RUN=0
TESTS_FAILED=0

fail() {
    echo "FAIL: $*" >&2
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

pass() {
    echo "PASS: $*"
    TESTS_RUN=$((TESTS_RUN + 1))
}

expect_success() {
    local label="$1"
    shift
    if "$@"; then
        pass "$label"
    else
        fail "$label"
    fi
}

expect_failure() {
    local label="$1"
    shift
    if "$@"; then
        fail "$label (expected failure)"
    else
        pass "$label"
    fi
}

make_fixture_plist() {
    local path="$1"
    cat >"$path" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>0.9.0</string>
    <key>CFBundleVersion</key>
    <string>4242</string>
    <key>ChromaGlowGitCommit</key>
    <string>deadbeefdeadbeefdeadbeefdeadbeefdeadbeef</string>
    <key>ChromaGlowGitBranch</key>
    <string>ios-ops/ci-build-numbering</string>
    <key>ChromaGlowBuildTimestamp</key>
    <string>2026-06-01T12:00:00Z</string>
    <key>ChromaGlowGitDirty</key>
    <string>0</string>
</dict>
</plist>
XML
}

run_verify() {
    CHROMAGLOW_BUILT_APP_PLIST="$1" \
    CHROMAGLOW_EXPECTED_MARKETING_VERSION="$2" \
    CHROMAGLOW_EXPECTED_BUILD_NUMBER="$3" \
    CHROMAGLOW_EXPECTED_COMMIT="$4" \
    CHROMAGLOW_EXPECTED_BRANCH="${5:-}" \
    CHROMAGLOW_EXPECTED_DIRTY="$6" \
    CHROMAGLOW_REPORT_PATH="${7:-}" \
    "$VERIFY_SCRIPT"
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

VALID_PLIST="${WORK_DIR}/valid.plist"
REPORT_PATH="${WORK_DIR}/report.txt"
make_fixture_plist "$VALID_PLIST"

# 1 valid fixture passes
expect_success "valid fixture passes" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0" "$REPORT_PATH"

# 2 missing plist path fails clearly
expect_failure "missing plist path fails clearly" \
    run_verify "${WORK_DIR}/missing.plist" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 3 missing marketing version fails
NO_MARKETING="${WORK_DIR}/no-marketing.plist"
cp "$VALID_PLIST" "$NO_MARKETING"
/usr/libexec/PlistBuddy -c "Delete :CFBundleShortVersionString" "$NO_MARKETING"
expect_failure "missing marketing version fails" \
    run_verify "$NO_MARKETING" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 4 wrong marketing version fails
expect_failure "wrong marketing version fails" \
    run_verify "$VALID_PLIST" "1.0.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 5 missing build number fails
NO_BUILD="${WORK_DIR}/no-build.plist"
cp "$VALID_PLIST" "$NO_BUILD"
/usr/libexec/PlistBuddy -c "Delete :CFBundleVersion" "$NO_BUILD"
expect_failure "missing build number fails" \
    run_verify "$NO_BUILD" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 6 wrong build number fails
expect_failure "wrong build number fails" \
    run_verify "$VALID_PLIST" "0.9.0" "9999" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 7 missing commit fails
NO_COMMIT="${WORK_DIR}/no-commit.plist"
cp "$VALID_PLIST" "$NO_COMMIT"
/usr/libexec/PlistBuddy -c "Delete :ChromaGlowGitCommit" "$NO_COMMIT"
expect_failure "missing commit fails" \
    run_verify "$NO_COMMIT" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 8 wrong commit fails
expect_failure "wrong commit fails" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "cafebabecafebabecafebabecafebabecafebabe" \
    "ios-ops/ci-build-numbering" "0"

# 9 optional expected branch omitted safely
expect_success "optional expected branch omitted safely" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "" "0"

# 10 expected branch present and correct passes
expect_success "expected branch present and correct passes" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 11 wrong branch fails
expect_failure "wrong branch fails" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "wrong-branch" "0"

# 12 missing timestamp fails
NO_TS="${WORK_DIR}/no-ts.plist"
cp "$VALID_PLIST" "$NO_TS"
/usr/libexec/PlistBuddy -c "Delete :ChromaGlowBuildTimestamp" "$NO_TS"
expect_failure "missing timestamp fails" \
    run_verify "$NO_TS" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 13 timestamp without trailing Z fails
BAD_TS="${WORK_DIR}/bad-ts.plist"
cp "$VALID_PLIST" "$BAD_TS"
/usr/libexec/PlistBuddy -c "Set :ChromaGlowBuildTimestamp 2026-06-01T12:00:00" "$BAD_TS"
expect_failure "timestamp without trailing Z fails" \
    run_verify "$BAD_TS" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

# 14 wrong dirty value fails
expect_failure "wrong dirty value fails" \
    run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "1"

# 15 report file is written
if [[ -f "$REPORT_PATH" && -s "$REPORT_PATH" ]]; then
    pass "report file is written"
else
    fail "report file is written"
fi

# 16 input plist remains unchanged
SOURCE_HASH="$(shasum -a 256 "$VALID_PLIST" | awk '{print $1}')"
run_verify "$VALID_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0" >/dev/null
AFTER_HASH="$(shasum -a 256 "$VALID_PLIST" | awk '{print $1}')"
if [[ "$SOURCE_HASH" == "$AFTER_HASH" ]]; then
    pass "input plist remains unchanged"
else
    fail "input plist remains unchanged"
fi

# 17 path containing spaces works
SPACE_DIR="${WORK_DIR}/repo with spaces"
mkdir -p "$SPACE_DIR"
SPACE_PLIST="${SPACE_DIR}/built.plist"
make_fixture_plist "$SPACE_PLIST"
expect_success "path containing spaces works" \
    run_verify "$SPACE_PLIST" "0.9.0" "4242" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "ios-ops/ci-build-numbering" "0"

echo ""
echo "Tests run: ${TESTS_RUN}, failed: ${TESTS_FAILED}"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
    exit 1
fi
