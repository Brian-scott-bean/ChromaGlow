#!/bin/bash
# verify_built_app_metadata.sh
# ChromaGlow — IOS-OPS-001D
#
# Validates a processed built-app Info.plist without modifying it.

set -euo pipefail

die() {
    echo "error: $*" >&2
    exit 1
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        die "missing required environment variable: ${name}"
    fi
}

plist_value() {
    local plist="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :${key}" "$plist" 2>/dev/null || true
}

require_env CHROMAGLOW_BUILT_APP_PLIST
require_env CHROMAGLOW_EXPECTED_MARKETING_VERSION
require_env CHROMAGLOW_EXPECTED_BUILD_NUMBER
require_env CHROMAGLOW_EXPECTED_COMMIT
require_env CHROMAGLOW_EXPECTED_DIRTY

PLIST="${CHROMAGLOW_BUILT_APP_PLIST}"
REPORT_PATH="${CHROMAGLOW_REPORT_PATH:-}"

if [[ ! -f "$PLIST" ]]; then
    die "built app plist not found: ${PLIST}"
fi

PLIST_BEFORE="$(shasum -a 256 "$PLIST" | awk '{print $1}')"

ACTUAL_MARKETING="$(plist_value "$PLIST" CFBundleShortVersionString)"
ACTUAL_BUILD="$(plist_value "$PLIST" CFBundleVersion)"
ACTUAL_COMMIT="$(plist_value "$PLIST" ChromaGlowGitCommit)"
ACTUAL_BRANCH="$(plist_value "$PLIST" ChromaGlowGitBranch)"
ACTUAL_TIMESTAMP="$(plist_value "$PLIST" ChromaGlowBuildTimestamp)"
ACTUAL_DIRTY="$(plist_value "$PLIST" ChromaGlowGitDirty)"

ERRORS=()

if [[ -z "$ACTUAL_MARKETING" ]]; then
    ERRORS+=("missing CFBundleShortVersionString")
elif [[ "$ACTUAL_MARKETING" != "$CHROMAGLOW_EXPECTED_MARKETING_VERSION" ]]; then
    ERRORS+=("CFBundleShortVersionString mismatch: expected '${CHROMAGLOW_EXPECTED_MARKETING_VERSION}', got '${ACTUAL_MARKETING}'")
fi

if [[ -z "$ACTUAL_BUILD" ]]; then
    ERRORS+=("missing CFBundleVersion")
elif [[ "$ACTUAL_BUILD" != "$CHROMAGLOW_EXPECTED_BUILD_NUMBER" ]]; then
    ERRORS+=("CFBundleVersion mismatch: expected '${CHROMAGLOW_EXPECTED_BUILD_NUMBER}', got '${ACTUAL_BUILD}'")
fi

if [[ -z "$ACTUAL_COMMIT" ]]; then
    ERRORS+=("missing ChromaGlowGitCommit")
elif [[ "$ACTUAL_COMMIT" != "$CHROMAGLOW_EXPECTED_COMMIT" ]]; then
    ERRORS+=("ChromaGlowGitCommit mismatch: expected '${CHROMAGLOW_EXPECTED_COMMIT}', got '${ACTUAL_COMMIT}'")
fi

if [[ -n "${CHROMAGLOW_EXPECTED_BRANCH:-}" ]]; then
    if [[ -z "$ACTUAL_BRANCH" ]]; then
        ERRORS+=("missing ChromaGlowGitBranch (expected '${CHROMAGLOW_EXPECTED_BRANCH}')")
    elif [[ "$ACTUAL_BRANCH" != "$CHROMAGLOW_EXPECTED_BRANCH" ]]; then
        ERRORS+=("ChromaGlowGitBranch mismatch: expected '${CHROMAGLOW_EXPECTED_BRANCH}', got '${ACTUAL_BRANCH}'")
    fi
fi

if [[ -z "$ACTUAL_TIMESTAMP" ]]; then
    ERRORS+=("missing ChromaGlowBuildTimestamp")
elif [[ "$ACTUAL_TIMESTAMP" != *Z ]]; then
    ERRORS+=("ChromaGlowBuildTimestamp must end with Z (got '${ACTUAL_TIMESTAMP}')")
fi

if [[ -z "$ACTUAL_DIRTY" ]]; then
    ERRORS+=("missing ChromaGlowGitDirty")
elif [[ "$ACTUAL_DIRTY" != "$CHROMAGLOW_EXPECTED_DIRTY" ]]; then
    ERRORS+=("ChromaGlowGitDirty mismatch: expected '${CHROMAGLOW_EXPECTED_DIRTY}', got '${ACTUAL_DIRTY}'")
fi

REPORT="$(cat <<EOF
ChromaGlow Built App Metadata Verification
==========================================
Plist: ${PLIST}

CFBundleShortVersionString: ${ACTUAL_MARKETING:-<missing>}
CFBundleVersion: ${ACTUAL_BUILD:-<missing>}
ChromaGlowGitCommit: ${ACTUAL_COMMIT:-<missing>}
ChromaGlowGitBranch: ${ACTUAL_BRANCH:-<missing>}
ChromaGlowBuildTimestamp: ${ACTUAL_TIMESTAMP:-<missing>}
ChromaGlowGitDirty: ${ACTUAL_DIRTY:-<missing>}

Expected marketing version: ${CHROMAGLOW_EXPECTED_MARKETING_VERSION}
Expected build number: ${CHROMAGLOW_EXPECTED_BUILD_NUMBER}
Expected commit: ${CHROMAGLOW_EXPECTED_COMMIT}
Expected branch: ${CHROMAGLOW_EXPECTED_BRANCH:-<not checked>}
Expected dirty state: ${CHROMAGLOW_EXPECTED_DIRTY}
EOF
)"

if [[ -n "$REPORT_PATH" ]]; then
    printf '%s\n' "$REPORT" >"$REPORT_PATH"
fi

printf '%s\n' "$REPORT"

PLIST_AFTER="$(shasum -a 256 "$PLIST" | awk '{print $1}')"
if [[ "$PLIST_BEFORE" != "$PLIST_AFTER" ]]; then
    die "built app plist was modified during verification"
fi

if [[ "${#ERRORS[@]}" -gt 0 ]]; then
    for message in "${ERRORS[@]}"; do
        echo "error: ${message}" >&2
    done
    exit 1
fi

echo "verify_built_app_metadata: PASS"
