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
#   2. H-03/H-04/L-09 — no `privacy: .public` os_log interpolation of a URL,
#              IP, token, client key, error text, or user-content name; no
#              token/clientKey interpolated into pairing appendLog; the v1
#              client never logs its token-bearing URL strings.

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
# Guard 2 (H-03/H-04/L-09): secrets & PII must never reach the unified log
# with `privacy: .public`, and pairing secrets must never enter appendLog.
#
# Line-level rule: a `privacy: .public` may not share a line with any
# identifier that carries a URL, IP, token, key, error text, or user-content
# name. If a value is safe to expose (status codes, counts, static paths),
# keep it on a line free of these identifiers.
# ──────────────────────────────────────────────────────────────

SWIFT_DIRS=("HueHome" "HueHomeWidget" "LightShadeWatch" "LightShadeWatchApp Watch App")

BAN_IDENTIFIERS='urlStr|absoluteString|request\.url|errorBody|bodyStr|\braw\b|\btoken\b|clientKey|localizedDescription|\bdescription\b|\.name\b|\bmsg\b|\bmessage\b|endpointDescription|\bdesc\b|\bip\b|\bhost\b|\burl\b'

pub_hits=$(grep -rn "privacy: \.public" "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null | grep -E "$BAN_IDENTIFIERS" || true)
if [[ -n "$pub_hits" ]]; then
    fail "H-03/H-04/L-09" $'privacy: .public on a URL/IP/token/name-derived interpolation:\n'"$pub_hits"
fi

applog_hits=$(grep -rnE 'appendLog\(.*\\\((token|clientKey)\)' "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null || true)
if [[ -n "$applog_hits" ]]; then
    fail "H-04" $'token/clientKey interpolated into appendLog:\n'"$applog_hits"
fi

v1_hits=$(grep -nE 'log\.(info|debug|error|warning|fault)\(.*\\\((urlStr|baseURL)' HueHome/Core/Network/HueV1Client.swift || true)
if [[ -n "$v1_hits" ]]; then
    fail "H-03" $'HueV1Client logs a token-bearing URL string:\n'"$v1_hits"
fi

# ──────────────────────────────────────────────────────────────

if [[ $FAILURES -gt 0 ]]; then
    echo "hardening_guards: $FAILURES guard(s) failed." >&2
    exit 1
fi
echo "hardening_guards: all guards passed."
