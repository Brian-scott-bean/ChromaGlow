#!/bin/bash
# test_inject_build_metadata.sh
# ChromaGlow — IOS-OPS-001B lightweight fixture tests for inject_build_metadata.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INJECT_SCRIPT="${REPO_ROOT}/Scripts/inject_build_metadata.sh"

if [[ ! -x "$INJECT_SCRIPT" ]]; then
    chmod +x "$INJECT_SCRIPT"
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

assert_equals() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "${label}: expected '${expected}', got '${actual}'"
        return 1
    fi
    pass "$label"
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

make_fixture_plist() {
    local path="$1"
    cat >"$path" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.huehome.pro.test</string>
</dict>
</plist>
XML
}

run_inject() {
    local repo="$1"
    local plist="$2"
    CHROMAGLOW_REPO_ROOT="$repo" CHROMAGLOW_METADATA_PLIST_PATH="$plist" "$INJECT_SCRIPT"
}

init_clean_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@chromaglow.local"
    git -C "$dir" config user.name "ChromaGlow Test"
    echo "base" >"$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# 1–3 clean repo
CLEAN_REPO="${WORK_DIR}/clean"
PLIST_CLEAN="${WORK_DIR}/clean.plist"
make_fixture_plist "$PLIST_CLEAN"
init_clean_repo "$CLEAN_REPO"
run_inject "$CLEAN_REPO" "$PLIST_CLEAN"
assert_equals "$(git -C "$CLEAN_REPO" rev-parse HEAD)" "$(plist_value "$PLIST_CLEAN" ChromaGlowGitCommit)" "clean repo injects commit SHA"
assert_equals "main" "$(plist_value "$PLIST_CLEAN" ChromaGlowGitBranch)" "clean repo injects branch name"
assert_equals "0" "$(plist_value "$PLIST_CLEAN" ChromaGlowGitDirty)" "clean repo injects dirty 0"

# 4 modified tracked file
MOD_REPO="${WORK_DIR}/modified"
PLIST_MOD="${WORK_DIR}/modified.plist"
make_fixture_plist "$PLIST_MOD"
init_clean_repo "$MOD_REPO"
echo "change" >>"$MOD_REPO/README.md"
run_inject "$MOD_REPO" "$PLIST_MOD"
assert_equals "1" "$(plist_value "$PLIST_MOD" ChromaGlowGitDirty)" "modified tracked file injects dirty 1"

# 5 staged file
STAGED_REPO="${WORK_DIR}/staged"
PLIST_STAGED="${WORK_DIR}/staged.plist"
make_fixture_plist "$PLIST_STAGED"
init_clean_repo "$STAGED_REPO"
echo "staged" >"$STAGED_REPO/staged.txt"
git -C "$STAGED_REPO" add staged.txt
run_inject "$STAGED_REPO" "$PLIST_STAGED"
assert_equals "1" "$(plist_value "$PLIST_STAGED" ChromaGlowGitDirty)" "staged file injects dirty 1"

# 6 non-ignored untracked file
UNTRACKED_REPO="${WORK_DIR}/untracked"
PLIST_UNTRACKED="${WORK_DIR}/untracked.plist"
make_fixture_plist "$PLIST_UNTRACKED"
init_clean_repo "$UNTRACKED_REPO"
echo "new" >"$UNTRACKED_REPO/new.txt"
run_inject "$UNTRACKED_REPO" "$PLIST_UNTRACKED"
assert_equals "1" "$(plist_value "$PLIST_UNTRACKED" ChromaGlowGitDirty)" "untracked file injects dirty 1"

# 7 ignored file does not mark dirty
IGNORED_REPO="${WORK_DIR}/ignored"
PLIST_IGNORED="${WORK_DIR}/ignored.plist"
make_fixture_plist "$PLIST_IGNORED"
init_clean_repo "$IGNORED_REPO"
echo "ignored/" >>"$IGNORED_REPO/.gitignore"
mkdir -p "$IGNORED_REPO/ignored"
echo "noise" >"$IGNORED_REPO/ignored/noise.txt"
git -C "$IGNORED_REPO" add .gitignore
git -C "$IGNORED_REPO" commit -q -m "gitignore"
run_inject "$IGNORED_REPO" "$PLIST_IGNORED"
assert_equals "0" "$(plist_value "$PLIST_IGNORED" ChromaGlowGitDirty)" "ignored file does not mark dirty"

# 8–9 detached HEAD
DETACHED_REPO="${WORK_DIR}/detached"
PLIST_DETACHED="${WORK_DIR}/detached.plist"
make_fixture_plist "$PLIST_DETACHED"
init_clean_repo "$DETACHED_REPO"
DETACHED_COMMIT="$(git -C "$DETACHED_REPO" rev-parse HEAD)"
git -C "$DETACHED_REPO" checkout -q HEAD~0 2>/dev/null || true
git -C "$DETACHED_REPO" checkout -q "$DETACHED_COMMIT" 2>/dev/null || true
git -C "$DETACHED_REPO" checkout -q --detach HEAD
run_inject "$DETACHED_REPO" "$PLIST_DETACHED"
assert_equals "$DETACHED_COMMIT" "$(plist_value "$PLIST_DETACHED" ChromaGlowGitCommit)" "detached HEAD injects commit SHA"
BRANCH_AFTER_DETACH="$(plist_value "$PLIST_DETACHED" ChromaGlowGitBranch)"
if [[ -n "$BRANCH_AFTER_DETACH" ]]; then
    fail "detached HEAD should omit branch metadata (got '${BRANCH_AFTER_DETACH}')"
else
    pass "detached HEAD omits branch metadata"
fi

# detached HEAD with branch override
PLIST_DETACHED_OVERRIDE="${WORK_DIR}/detached-override.plist"
make_fixture_plist "$PLIST_DETACHED_OVERRIDE"
CHROMAGLOW_GIT_BRANCH_OVERRIDE="ios-ops/ci-build-numbering" \
    run_inject "$DETACHED_REPO" "$PLIST_DETACHED_OVERRIDE"
assert_equals "ios-ops/ci-build-numbering" \
    "$(plist_value "$PLIST_DETACHED_OVERRIDE" ChromaGlowGitBranch)" \
    "detached HEAD with override injects branch override"

# branch override on clean repo still works alongside local detection
PLIST_OVERRIDE="${WORK_DIR}/override.plist"
make_fixture_plist "$PLIST_OVERRIDE"
CHROMAGLOW_GIT_BRANCH_OVERRIDE="feature/with/slash" \
    run_inject "$CLEAN_REPO" "$PLIST_OVERRIDE"
assert_equals "feature/with/slash" \
    "$(plist_value "$PLIST_OVERRIDE" ChromaGlowGitBranch)" \
    "branch override with slash is stored correctly"

# 10 non-Git directory
NOGIT_DIR="${WORK_DIR}/nogit"
PLIST_NOGIT="${WORK_DIR}/nogit.plist"
make_fixture_plist "$PLIST_NOGIT"
mkdir -p "$NOGIT_DIR"
run_inject "$NOGIT_DIR" "$PLIST_NOGIT"
if [[ -n "$(plist_value "$PLIST_NOGIT" ChromaGlowGitCommit)" ]]; then
    fail "non-git directory should omit commit metadata"
else
    pass "non-git directory omits commit metadata"
fi
if [[ -n "$(plist_value "$PLIST_NOGIT" ChromaGlowGitBranch)" ]]; then
    fail "non-git directory should omit branch metadata"
else
    pass "non-git directory omits branch metadata"
fi
if [[ -n "$(plist_value "$PLIST_NOGIT" ChromaGlowGitDirty)" ]]; then
    fail "non-git directory should omit dirty metadata"
else
    pass "non-git directory omits dirty metadata"
fi

# 11 timestamp injected
if [[ -z "$(plist_value "$PLIST_CLEAN" ChromaGlowBuildTimestamp)" ]]; then
    fail "timestamp should be injected"
else
    pass "timestamp is injected"
fi

# 12 update without duplication
FIRST_TS="$(plist_value "$PLIST_CLEAN" ChromaGlowBuildTimestamp)"
sleep 1
run_inject "$CLEAN_REPO" "$PLIST_CLEAN"
SECOND_TS="$(plist_value "$PLIST_CLEAN" ChromaGlowBuildTimestamp)"
COMMIT_COUNT="$(/usr/libexec/PlistBuddy -c "Print :ChromaGlowGitCommit" "$PLIST_CLEAN" 2>&1 | wc -l | tr -d ' ')"
if [[ "$COMMIT_COUNT" != "1" ]]; then
    fail "commit key should not be duplicated"
else
    pass "existing keys update without duplication"
fi
if [[ "$FIRST_TS" == "$SECOND_TS" ]]; then
    fail "timestamp should update on second run"
else
    pass "timestamp updates on second run"
fi

# 13 stale keys removed when Git metadata unavailable
STALE_PLIST="${WORK_DIR}/stale.plist"
make_fixture_plist "$STALE_PLIST"
/usr/libexec/PlistBuddy -c "Add :ChromaGlowGitCommit string deadbeef" "$STALE_PLIST"
/usr/libexec/PlistBuddy -c "Add :ChromaGlowGitBranch string stale-branch" "$STALE_PLIST"
/usr/libexec/PlistBuddy -c "Add :ChromaGlowGitDirty string 1" "$STALE_PLIST"
run_inject "$NOGIT_DIR" "$STALE_PLIST"
if [[ -n "$(plist_value "$STALE_PLIST" ChromaGlowGitCommit)" || -n "$(plist_value "$STALE_PLIST" ChromaGlowGitBranch)" || -n "$(plist_value "$STALE_PLIST" ChromaGlowGitDirty)" ]]; then
    fail "stale optional keys should be removed when Git is unavailable"
else
    pass "stale optional keys removed when Git unavailable"
fi

# 14 repo path containing spaces
SPACE_ROOT="${WORK_DIR}/repo with spaces"
SPACE_PLIST="${WORK_DIR}/space.plist"
make_fixture_plist "$SPACE_PLIST"
init_clean_repo "$SPACE_ROOT"
run_inject "$SPACE_ROOT" "$SPACE_PLIST"
assert_equals "$(git -C "$SPACE_ROOT" rev-parse HEAD)" "$(plist_value "$SPACE_PLIST" ChromaGlowGitCommit)" "repo path with spaces works"

# 15 missing plist path fails clearly
if CHROMAGLOW_METADATA_PLIST_PATH="${WORK_DIR}/missing.plist" CHROMAGLOW_REPO_ROOT="$CLEAN_REPO" "$INJECT_SCRIPT" >/dev/null 2>&1; then
    fail "missing plist path should fail"
else
    pass "missing plist path fails with actionable error"
fi

# 16 source fixture unchanged unless selected
SOURCE_FIXTURE="${REPO_ROOT}/HueHome/Info.plist"
SOURCE_BEFORE="$(shasum -a 256 "$SOURCE_FIXTURE" | awk '{print $1}')"
run_inject "$CLEAN_REPO" "$PLIST_CLEAN"
SOURCE_AFTER="$(shasum -a 256 "$SOURCE_FIXTURE" | awk '{print $1}')"
assert_equals "$SOURCE_BEFORE" "$SOURCE_AFTER" "source HueHome/Info.plist remains unchanged"

echo ""
echo "Tests run: ${TESTS_RUN}, failed: ${TESTS_FAILED}"
if [[ "$TESTS_FAILED" -ne 0 ]]; then
    exit 1
fi
