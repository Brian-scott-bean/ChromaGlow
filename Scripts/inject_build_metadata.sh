#!/bin/bash
# inject_build_metadata.sh
# ChromaGlow — IOS-OPS-001B
#
# Injects build provenance into the processed app-bundle Info.plist only.
# Never modifies HueHome/Info.plist (source).

set -euo pipefail

readonly KEYS_COMMIT="ChromaGlowGitCommit"
readonly KEYS_BRANCH="ChromaGlowGitBranch"
readonly KEYS_TIMESTAMP="ChromaGlowBuildTimestamp"
readonly KEYS_DIRTY="ChromaGlowGitDirty"

resolve_repo_root() {
    if [[ -n "${CHROMAGLOW_REPO_ROOT:-}" ]]; then
        printf '%s\n' "$CHROMAGLOW_REPO_ROOT"
        return 0
    fi
    if [[ -n "${SRCROOT:-}" ]]; then
        if git -C "$SRCROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
            git -C "$SRCROOT" rev-parse --show-toplevel
            return 0
        fi
        printf '%s\n' "$SRCROOT"
        return 0
    fi
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
        git rev-parse --show-toplevel
        return 0
    fi
    printf '%s\n' "$(pwd)"
}

resolve_plist_path() {
    if [[ -n "${CHROMAGLOW_METADATA_PLIST_PATH:-}" ]]; then
        printf '%s\n' "$CHROMAGLOW_METADATA_PLIST_PATH"
        return 0
    fi
    if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${INFOPLIST_PATH:-}" ]]; then
        echo "error: set CHROMAGLOW_METADATA_PLIST_PATH or build with TARGET_BUILD_DIR and INFOPLIST_PATH" >&2
        return 1
    fi
    printf '%s\n' "${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
}

plist_key_exists() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" >/dev/null 2>&1
}

set_plist_string() {
    local plist="$1"
    local key="$2"
    local value="$3"
    if plist_key_exists "$plist" "$key"; then
        /usr/libexec/PlistBuddy -c "Set :${key} \"${value}\"" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string \"${value}\"" "$plist"
    fi
}

delete_plist_key() {
    local plist="$1"
    local key="$2"
    if plist_key_exists "$plist" "$key"; then
        /usr/libexec/PlistBuddy -c "Delete :${key}" "$plist"
    fi
}

REPO_ROOT="$(resolve_repo_root)"
PLIST="$(resolve_plist_path)"

if [[ ! -f "$PLIST" ]]; then
    if [[ -n "${CHROMAGLOW_METADATA_PLIST_PATH:-}" ]]; then
        echo "error: metadata plist not found: ${PLIST}" >&2
        exit 1
    fi
    echo "note: metadata plist not found yet (${PLIST}); skipping until ProcessInfoPlist creates it" >&2
    exit 0
fi

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set_plist_string "$PLIST" "$KEYS_TIMESTAMP" "$TIMESTAMP"

if COMMIT_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)"; then
    set_plist_string "$PLIST" "$KEYS_COMMIT" "$COMMIT_SHA"
else
    delete_plist_key "$PLIST" "$KEYS_COMMIT"
fi

BRANCH_NAME=""
if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BRANCH_NAME="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
fi

if [[ -n "$BRANCH_NAME" && "$BRANCH_NAME" != "HEAD" ]]; then
    set_plist_string "$PLIST" "$KEYS_BRANCH" "$BRANCH_NAME"
else
    delete_plist_key "$PLIST" "$KEYS_BRANCH"
fi

if git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
        set_plist_string "$PLIST" "$KEYS_DIRTY" "1"
    else
        set_plist_string "$PLIST" "$KEYS_DIRTY" "0"
    fi
else
    delete_plist_key "$PLIST" "$KEYS_DIRTY"
fi
