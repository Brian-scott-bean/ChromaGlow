#!/bin/bash
# hardening_guards.sh — regression guards for the 2026-07-01 hardening audit.
#
# Run from the repo root:  ./Scripts/hardening_guards.sh
# Exits non-zero if any guard fails. Each guard maps to audit finding IDs
# (docs/audit/hardening-audit-2026-07-01.md) so a failure names its finding.
#
# Guards:
#   1. M-03  — every shippable bundle ships a PrivacyInfo.xcprivacy declaring
#              the UserDefaults required-reason API (ITMS-91053 upload blocker).

set -u
cd "$(dirname "$0")/.."

FAILURES=0

fail() {
    echo "GUARD FAIL [$1]: $2" >&2
    FAILURES=$((FAILURES + 1))
}

# ──────────────────────────────────────────────────────────────
# Guard 1 (M-03): per-bundle privacy manifests
#
# The widget + watch targets are file-system-synchronized groups, so presence
# of the manifest inside the target folder IS target membership. The main app
# target uses a classic group and needs the explicit pbxproj Resources entry.
# ──────────────────────────────────────────────────────────────

PRIVACY_BUNDLE_DIRS=(
    "HueHome"
    "HueHomeWidget"
    "LightShadeWatch"
    "LightShadeWatchApp Watch App"
)

for dir in "${PRIVACY_BUNDLE_DIRS[@]}"; do
    manifest="$dir/PrivacyInfo.xcprivacy"
    if [[ ! -f "$manifest" ]]; then
        fail "M-03" "missing privacy manifest: $manifest"
        continue
    fi
    if ! grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$manifest"; then
        fail "M-03" "$manifest does not declare NSPrivacyAccessedAPICategoryUserDefaults"
    fi
    if ! grep -q "CA92.1" "$manifest"; then
        fail "M-03" "$manifest does not declare required reason CA92.1"
    fi
done

# Main app target wires its manifest via an explicit Resources build phase entry.
if ! grep -q "PrivacyInfo.xcprivacy in Resources" HueHome.xcodeproj/project.pbxproj; then
    fail "M-03" "main app target lost its 'PrivacyInfo.xcprivacy in Resources' pbxproj entry"
fi

# ──────────────────────────────────────────────────────────────

if [[ $FAILURES -gt 0 ]]; then
    echo "hardening_guards: $FAILURES guard(s) failed." >&2
    exit 1
fi
echo "hardening_guards: all guards passed."
