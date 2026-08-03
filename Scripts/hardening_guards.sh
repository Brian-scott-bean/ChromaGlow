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
#   3. H-01/H-02/M-01 — no trust-all TLS: `.useCredential` may exist only in
#              the pinned-trust module, and a discarded SecTrustEvaluate
#              result is banned everywhere.
#   4. M-02/L-30 — the bridge token never re-enters UserDefaults: no `set(`
#              write against a known plaintext-token key (App Group or watch),
#              and no `.token` value written into any UserDefaults suite.
#   5. M-07/H-05/M-18 — no room-targeted write path may use primaryAPIClient
#              (= clients.values.first, nondeterministic wrong-bridge class).
#              Resolve per-bridge via hueClient(for:)/hueClient(forBridgeIP:).
#   6. Round C terminology — banned user-facing jargon literals.
#   7. Composer 2 packet 4 — CompositionRoomPriorityScorerTests must stay
#              deterministic: no Task.sleep, XCTWaiter, or wait(for:timeout:).
#   8. Composer 2 packet 5 — no re-introduced light/channel cap: the render
#              and bridge-stored paths must not clamp a room to a literal
#              count, and `channelBudget` must stay gone.

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

# The main app's manifest lives at the repo ROOT since build 28 (the orphan
# duplicate at HueHome/ was deleted; the root file is the live one).
PRIVACY_BUNDLE_DIRS=(
    "."
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
# Guard 3 (H-01/H-02/M-01/H-06): trust-all TLS must never return.
#
# The ONLY place allowed to return `.useCredential` for a server-trust
# challenge is the pinned-trust module, whose delegates gate it behind a
# successful SecTrustEvaluateWithError + bridgeid-CN + pin match.
# ──────────────────────────────────────────────────────────────

TRUST_MODULE="HueHome/Core/Network/Trust/"

trustall_hits=$(grep -rn "useCredential" "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null | grep -v "^${TRUST_MODULE}" || true)
if [[ -n "$trustall_hits" ]]; then
    fail "H-01/H-02/M-01" $'.useCredential outside the pinned-trust module:\n'"$trustall_hits"
fi

discard_hits=$(grep -rn "_ = SecTrustEvaluateWithError" "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null || true)
if [[ -n "$discard_hits" ]]; then
    fail "H-01" $'SecTrustEvaluateWithError result discarded:\n'"$discard_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 4 (M-02/L-30): plaintext bridge tokens must never return to
# UserDefaults. Deleting/reading the legacy keys is fine (migration/scrub);
# a `set(` write against them — or of any `.token` value — is a regression.
# ──────────────────────────────────────────────────────────────

TOKEN_KEYS='"hue_widget_token"|"wc_token"|"hue_widget_bridges_v1"|"wc_bridges_v1"'

tokenkey_hits=$(grep -rnE "\.set\(.*forKey: ($TOKEN_KEYS)" "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null || true)
if [[ -n "$tokenkey_hits" ]]; then
    fail "M-02/L-30" $'UserDefaults write against a plaintext-token key:\n'"$tokenkey_hits"
fi

tokenval_hits=$(grep -rnE '(ud|defaults|userDefaults|watchGroup|group)[?]?\.set\((first|creds|fallback)[?]?\.token' "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null || true)
if [[ -n "$tokenval_hits" ]]; then
    fail "M-02/L-30" $'a .token value is written into a UserDefaults suite:\n'"$tokenval_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 5 (M-07/H-05/M-18): primaryAPIClient must never re-enter a write path.
#
# P1 swept every call site to per-bridge resolution (hueClient(for:) /
# hueClient(forBridgeIP:)). The ONLY allowed appearances are its own
# declaration inside UnifiedOrchestrator and comments. Any new code reference
# is treated as a wrong-bridge regression — if a legitimate non-room use ever
# appears, it must be justified by editing this guard.
# ──────────────────────────────────────────────────────────────

primary_hits=$(grep -rn "primaryAPIClient" "${SWIFT_DIRS[@]}" --include='*.swift' 2>/dev/null \
    | grep -vE '^\S+:[0-9]+:\s*//' \
    | grep -v "var primaryAPIClient: HueAPIClient? {" || true)
if [[ -n "$primary_hits" ]]; then
    fail "M-07/H-05/M-18" $'primaryAPIClient used outside its declaration (wrong-bridge class):\n'"$primary_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 6 (Round C terminology): banned user-facing jargon.
#
# The 2026-07 terminology sweep removed developer words from every display
# string (one TransportVocabulary source). These fixed literals can only
# reappear as display text — if one returns, the sweep is regressing.
# ──────────────────────────────────────────────────────────────

JARGON_PATTERNS=(
    '(REST)'
    '[REST'
    'REST_ONE_SHOT'
    'ENT AREA'
    'Runtime-only REST'
    'rate-capped'
    'mock data'
    'low-latency'
    'ultra-low-latency'
    'Wi-Fi scan (mDNS)'
    'Devices & Firmware'
    'CT APPROX'
    'has no grouped light'
    '"Onset"'
)

for pattern in "${JARGON_PATTERNS[@]}"; do
    hits=$(grep -RFl -- "$pattern" HueHome/UI HueHome/Core/Models/TutorialCatalog.swift 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        fail "terminology" $'banned user-facing jargon "'"$pattern"$'" found in:\n'"$hits"
    fi
done

# ──────────────────────────────────────────────────────────────
# Guard 7 (Composer 2 packet 4): the pure ledger/scorer tests must stay
# deterministic. CompositionSendLedger takes every timestamp as a parameter
# precisely so nothing in its test file ever waits — a sleep or waiter here
# means someone is proving telemetry with elapsed time again.
# ──────────────────────────────────────────────────────────────

LEDGER_TESTS="HueHomeTests/CompositionRoomPriorityScorerTests.swift"

wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$LEDGER_TESTS" 2>/dev/null || true)
if [[ -n "$wait_hits" ]]; then
    fail "composer-p4" $'timing wait in the pure ledger/scorer tests:\n'"$wait_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 8 (Composer 2 packet 5): the phantom 20-light cap must not come back.
#
# It was one literal copied to three places, and every copy existed only to
# keep the trapping `UInt8(_:)` initialiser safe on a render-channel index.
# With `LightFrame.channelID` an Int there is no reason to clamp a room to a
# count anywhere, so any `UInt8(min(` or `channelBudget` in these files is a
# regression — including a well-meaning "safety" clamp, which is exactly how
# the original arrived.
# ──────────────────────────────────────────────────────────────

CAP_FILES=(
    "HueHome/Core/Network/UnifiedOrchestrator.swift"
    "HueHome/Core/Network/BridgeAnimationEngine.swift"
    "HueHome/Core/Composer/GradientChannelMap.swift"
)

for f in "${CAP_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Strip comment-only lines so the explanatory history above each fix
    # (which necessarily quotes the old expression) does not trip the guard.
    cap_hits=$(grep -nE 'UInt8\(min\(|channelBudget' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$cap_hits" ]]; then
        fail "composer-p5" $'re-introduced light/channel cap in '"$f"$':\n'"$cap_hits"
    fi
done

# The pure rotation arithmetic lives in the ledger/scorer test file, which
# Guard 7 already keeps free of timing waits — extend the same rule to the
# packet-5 orchestrator tests, whose fairness claims must never rest on a
# sleep either.
ROTATION_TESTS="HueHomeTests/MultiBridgeRoutingTests.swift"
rot_wait_hits=$(grep -nE 'XCTWaiter|wait\(for:' "$ROTATION_TESTS" 2>/dev/null || true)
if [[ -n "$rot_wait_hits" ]]; then
    fail "composer-p5" $'timing waiter in the composer routing tests:\n'"$rot_wait_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 9 (Composer 2 packet 7): ChromaGlow yields to third-party
# Entertainment sessions.
#
# The old rule was "active and not owned by this process means stop", which
# ran unattended from loadAll and evicted a Sync Box or another Hue app the
# user was actively watching. Ownership is now keyed by bridge AND
# configuration, and persisted, so cleanup can recognise its OWN orphaned
# sessions without touching anyone else's.
#
# A configuration id on its own is not an identity — any return of the
# configID-only registry is the defect coming back.
# ──────────────────────────────────────────────────────────────

OWNERSHIP_FILES=(
    "HueHome/Core/Network/UnifiedOrchestrator.swift"
    "HueHome/Core/Network/HueEntertainmentClient.swift"
)

for f in "${OWNERSHIP_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Strip comment-only lines: the history above each fix necessarily names
    # the old symbols.
    own_hits=$(grep -nE 'isAppOwnedSession|registerActiveSession|unregisterActiveSession' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$own_hits" ]]; then
        fail "composer-p7" $'configID-only entertainment ownership re-introduced in '"$f"$':\n'"$own_hits"
    fi
done

# The consent prompt is the one place a third-party session is ever stopped,
# so its copy must stay free of transport/protocol jargon. Guard 6 covers the
# fixed literals; these are the packet-7 additions the prompt could leak.
P7_UI_FILES=(
    "HueHome/UI/Studio/StudioView.swift"
    "HueHome/UI/Studio/StudioViewModel.swift"
)

for f in "${P7_UI_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # Comment-only lines and developer diagnostics are excluded: debugLog and
    # os_log never reach a user, and naming the transport there is how the
    # next reader learns what the code actually does.
    jargon_hits=$(grep -nE '"[^"]*(DTLS|entertainment_configuration|configuration ID|session registry)[^"]*"' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' \
        | grep -vE 'debugLog\(|log\.(info|warning|error|debug)|print\(' || true)
    if [[ -n "$jargon_hits" ]]; then
        fail "composer-p7" $'protocol jargon in a user-facing string in '"$f"$':\n'"$jargon_hits"
    fi
done

# Packet 7's ownership claims are about ORDER and PRESENCE — never elapsed
# time. Same rule Guards 7/8 apply to the packets before it.
OWNERSHIP_TESTS="HueHomeTests/EntertainmentRobustnessTests.swift"
own_wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$OWNERSHIP_TESTS" 2>/dev/null || true)
if [[ -n "$own_wait_hits" ]]; then
    fail "composer-p7" $'timing wait in the entertainment ownership tests:\n'"$own_wait_hits"
fi

# ──────────────────────────────────────────────────────────────

if [[ $FAILURES -gt 0 ]]; then
    echo "hardening_guards: $FAILURES guard(s) failed." >&2
    exit 1
fi
echo "hardening_guards: all guards passed."
