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
#   9. Composer 2 packet 7 — no configID-only Entertainment ownership, no
#              protocol jargon in Studio's user-facing strings, and no timing
#              waits in the ownership tests.
#  10. Composer 2 packet 8 — bridge-stored manifest evidence may be destroyed
#              only through one exact-identity funnel: no roomID-only removal,
#              no global CG_ purge on the launch path, no dropping a manifest
#              because its bridge client is momentarily unavailable, and no
#              timing waits in the reconciliation tests.
#  11. Composer 2 packet 7 follow-up — cached availability may never disable
#              the only action that refreshes it; the ChromaGlow-owned handoff
#              and the third-party consent stay two concepts with two token
#              ledgers; no unattended surface asks the ownership question; and
#              the Reduce Motion refusal has exactly one literal.
#  12. composer-hardware-convergence — the exact-target decision may not
#              re-collapse into a silent pick, the three consent ledgers stay
#              disjoint, a stop is never treated as proof of release, the
#              bridge-save action stays reachable outside Palette → More, the
#              room wheel is not force-covered by the effect panel, and the
#              new suites carry no timing waits. Round 3: every Entertainment
#              commit goes through verifyAndCommitEntertainment (no bare
#              commit path), the shared save-outcome mailbox stays dead
#              (bridgeSaveRequestID replaces it), and the Clean Bridge
#              confirmation speaks only about its FROZEN id — never the live
#              re-resolution. Round 4c (j): bridge-stored cleanup is exact
#              identity (ownership ledger + one shared withdraw). Round 4d
#              (k): the exact stop target survives the Now Playing handoff
#              and removed-group teardown matches recorded bridge+room.
#              Round 4e (l): the LIVE runtime authority is exactly keyed —
#              CompositionPlaybackKey runtimes/generations/order, exact
#              transport claims (inert saves claim nothing), bridge-
#              authoritative Entertainment teardown, and bridge+room-exact
#              SSE suppression.

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


# ──── Guard 10 (composer-p8): manifest evidence is destroyed only on proof ────
# A bridge-stored animation runs on the bridge's own firmware, so the persisted
# manifest is the ONLY app-side record of resources that keep firing after a
# force-quit. Four shapes destroy that record, and every one of them is
# invisible to a green suite that never staged the exact situation:
#
#   (a) removing a manifest by roomID — or by presetID+roomID, the pre-packet-8
#       key. The same room id exists on two bridges, and after the rekey the
#       same preset legitimately has two manifests in one room. Exact identity
#       (`remove(id:`) is the only sanctioned spelling.
#   (b) reaching `purgeAllChromaGlowResources` from the launch path. That is
#       packet 2's cross-room destruction defect re-entering through the one
#       door packet 2 never had: a reconciler that runs on every launch.
#   (c) dropping a manifest because its bridge client is not registered YET. At
#       launch that is the NORMAL state — the bridge may be asleep, moved, or
#       its fetch still in flight. Forgetting it there is permanent, and it is
#       exactly what the code did before this packet. Structural fix: removal
#       has ONE funnel, and that funnel returns early unless the typed cleanup
#       result says the resources are actually gone.
#   (d) proving any of the above with elapsed time. Same rule Guards 7/8/9
#       apply to the packets before it.
#
# Two packet-8 rules are function-scoped rather than file-scoped and live in
# the suite instead, using packet 2's source-shape pattern: that the reconciler
# is called from `loadAll` AFTER the bridge fetch and room rebuild, and that
# destructive selection inside `stopCompositionMode` /
# `cleanupBridgeStoredAnimationForReplacement` always goes through
# `exactManifests(`. A grep cannot express ordering or containment within one
# function body.
# ──────────────────────────────────────────────────────────────

P8_SOURCES=(
    "HueHome/Core/Network/UnifiedOrchestrator.swift"
    "HueHome/Core/Persistence/BridgeAnimationStore.swift"
    "HueHome/UI/Studio/StudioViewModel.swift"
)

# (a) The roomID-only / preset+room destructive API stays gone. Comment-only
#     lines are stripped: the history above each fix necessarily names the old
#     call, and deleting documentation to satisfy a grep is backwards.
for f in "${P8_SOURCES[@]}"; do
    [[ -f "$f" ]] || continue
    p8_key_hits=$(grep -nE 'remove\(presetID:|remove\(roomID:|removeManifests\(roomID:|isRunningOnBridge\(presetID:|ownedManifests\(roomID: [^,)]+\)' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$p8_key_hits" ]]; then
        fail "composer-p8" $'roomID-only destructive manifest removal in '"$f"$':\n'"$p8_key_hits"
    fi
done

# (b) The launch path may not reach the global CG_ purge. Deliberately the
#     shell twin of testGlobalBridgeAnimationPurgeIsWiredOnlyToExplicitMaintenance:
#     this still reports when the test target does not build, which is exactly
#     when someone is mid-refactor of these APIs.
p8_purge_hits=$(grep -nE 'purgeAllChromaGlowResources' \
    "HueHome/Core/Network/UnifiedOrchestrator.swift" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -n "$p8_purge_hits" ]]; then
    fail "composer-p8" $'the launch reconciler can reach the global CG_ purge:\n'"$p8_purge_hits"
fi

# (c) ONE removal funnel, gated on the cleanup RESULT, and no second call site
#     to bypass it. Before this packet there were two, one of which removed the
#     manifest in the else-branch of a failed client lookup.
P8_STORE_OWNER="HueHome/Core/Network/UnifiedOrchestrator.swift"

if ! grep -q 'private func retireManifest(' "$P8_STORE_OWNER"; then
    fail "composer-p8" "the single manifest-removal funnel (retireManifest) is missing from $P8_STORE_OWNER"
fi

if ! grep -q 'private func exactManifests(bridgeID:' "$P8_STORE_OWNER"; then
    fail "composer-p8" "the exact-identity manifest selector (exactManifests) is missing from $P8_STORE_OWNER"
fi

p8_remove_sites=$(grep -cE 'bridgeAnimationStore\.remove\(' "$P8_STORE_OWNER" 2>/dev/null || echo 0)
if [[ "$p8_remove_sites" -gt 2 ]]; then
    fail "composer-p8" "expected at most 2 bridgeAnimationStore.remove( call sites (the funnel and the proved-absent prune), found $p8_remove_sites in $P8_STORE_OWNER"
fi

p8_unreadable_hits=$(grep -nE 'case \.bridgeUnreadable' "$P8_STORE_OWNER" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -z "$p8_unreadable_hits" ]]; then
    fail "composer-p8" "retireManifest must handle .bridgeUnreadable explicitly — an unreadable bridge is a reason to WAIT, never a reason to forget"
fi

# A client that cannot be resolved right now is not evidence about the bridge.
# The pre-packet-8 code logged exactly this sentence while dropping the manifest.
p8_drop_hits=$(grep -rnE 'dropping manifest without bridge cleanup' "${P8_SOURCES[@]}" 2>/dev/null || true)
if [[ -n "$p8_drop_hits" ]]; then
    fail "composer-p8" $'a manifest is dropped because its bridge client is unavailable:\n'"$p8_drop_hits"
fi

# (d) Packet 8's claims are about ORDER, PRESENCE and RESOURCE IDENTITY — never
#     elapsed time. Comment-only lines are stripped so the rule's own prose
#     (MultiBridgeRoutingTests.swift names Task.sleep in a comment, and must
#     keep doing so) does not trip the guard that describes it.
P8_TESTS=(
    "HueHomeTests/MultiBridgeRoutingTests.swift"
    "HueHomeTests/BridgeAnimationCorrectnessTests.swift"
)

for f in "${P8_TESTS[@]}"; do
    [[ -f "$f" ]] || continue
    p8_wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$p8_wait_hits" ]]; then
        fail "composer-p8" $'timing wait in the bridge-stored reconciliation tests: '"$f"$':\n'"$p8_wait_hits"
    fi
done

# ──────────────────────────────────────────────────────────────
# Guard 11 (Composer 2 packet 7 follow-up): stale caches, self-collision,
# silent refusals. Three device-discovered defects, one guard.
#
# (a) The Entertainment transport row was `.disabled(!availability.canStream)`
#     against a CACHED verdict — and tapping that row was the only thing that
#     would ever refresh the cache. An area created in the Hue app therefore
#     stayed undiscoverable until the app was force-quit, which made packet 7's
#     takeover prompt unreachable on real hardware. A cached no may explain
#     itself; it may not disable its own remedy.
#
# (b) A ChromaGlow Strobe session is process-owned, so packet 7's foreign set
#     is empty and its consent flow is deliberately a no-op against it. A
#     streaming composition therefore opened a SECOND session on a bridge we
#     were already streaming, and the failure was reported as a technical
#     inability — which every caller reads as licence to play REST underneath
#     a live 25 fps stream. The fix is a THIRD concept, not a widened second
#     one: merging the two tokens would make "is this ours?" unanswerable
#     again, which is the defect packet 7 existed to fix.
#
# (c) The Reduce Motion refusal wrote `statusMessage` and returned. Nothing in
#     the app renders `statusMessage`, so the refusal was silent: the user
#     tapped Strobe and nothing happened, with no explanation anywhere.
# ──────────────────────────────────────────────────────────────

# (a) Cached availability must not gate the action that refreshes it.
P7F_AVAILABILITY_UI=(
    "HueHome/UI/Studio/StudioView.swift"
    "HueHome/UI/Studio/MixerTrayView.swift"
)

for f in "${P7F_AVAILABILITY_UI[@]}"; do
    [[ -f "$f" ]] || continue
    p7f_disabled_hits=$(grep -nE '\.disabled\([^)]*canStream' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$p7f_disabled_hits" ]]; then
        fail "composer-p7-followup" $'cached Entertainment availability disables the only action that refreshes it in '"$f"$':\n'"$p7f_disabled_hits"
    fi
done

# (b1) Both concepts must exist, separately, in both layers. A missing symbol
#      here means one of them was folded into the other.
P7F_VM="HueHome/UI/Studio/StudioViewModel.swift"
P7F_ORCH="HueHome/Core/Network/UnifiedOrchestrator.swift"

for sym in 'var studioHandoffRequest' 'var foreignTakeoverRequest' \
           'func confirmStudioHandoff(' 'func cancelStudioHandoff(' \
           'func confirmForeignTakeover(' 'func cancelForeignTakeover(' \
           'func confirmEntertainmentHandoff('; do
    if ! grep -q "$sym" "$P7F_VM"; then
        fail "composer-p7-followup" "the handoff concepts collapsed into one: '$sym' is missing from $P7F_VM"
    fi
done

for sym in 'func resolveStudioHandoff(' 'func resolveForeignTakeover(' \
           'func studioOwningEntertainment(' 'func compositionOwningEntertainment(' \
           'case heldByAnotherChromaGlowLook'; do
    if ! grep -q "$sym" "$P7F_ORCH"; then
        fail "composer-p7-followup" "'$sym' is missing from $P7F_ORCH — a ChromaGlow-owned collision would be misreported as a technical failure again"
    fi
done

# (b2) The two ledgers may never touch. One authorizes replacing ANOTHER app's
#      session; the other authorizes stopping our own look.
p7f_token_hits=$(grep -nE 'consumedEntertainmentConsents.*[Ss]tudioHandoff|[Ss]tudioHandoff.*consumedEntertainmentConsents|consumedStudioHandoffRequests.*EntertainmentConsent' \
    "$P7F_ORCH" "$P7F_VM" 2>/dev/null | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$p7f_token_hits" ]]; then
    fail "composer-p7-followup" $'the ChromaGlow-owned handoff and the third-party consent share a token ledger:\n'"$p7f_token_hits"
fi

# (c) No unattended surface may ask the ownership question. Availability
#     refreshes run from loadAll, foreground and pull-to-refresh; a prompt or a
#     stop from there is something the user never asked for.
p7f_unattended=$(grep -rnE 'foreignTakeoverPreflight\(|resolveForeignTakeover\(|resolveStudioHandoff\(|entertainmentActivity\(onBridge:' \
    HueHome 2>/dev/null \
    | grep -vE "^($P7F_ORCH|$P7F_VM):" \
    | grep -vE ':[0-9]+:[[:space:]]*//' || true)
if [[ -n "$p7f_unattended" ]]; then
    fail "composer-p7-followup" $'an ownership question is asked outside the orchestrator and the Studio view model:\n'"$p7f_unattended"
fi

# (d) One literal for the Reduce Motion refusal, in the copy home, so Studio
#     and Perform cannot drift apart.
p7f_rm_home=$(grep -c 'Strobe is unavailable while Reduce Motion is on\.' "$P7F_ORCH" 2>/dev/null || echo 0)
if [[ "$p7f_rm_home" -ne 1 ]]; then
    fail "composer-p7-followup" "expected exactly 1 declaration of the Reduce Motion sentence in $P7F_ORCH, found $p7f_rm_home"
fi

p7f_rm_copies=$(grep -rn 'Strobe is unavailable while Reduce Motion is on\.' HueHome 2>/dev/null \
    | grep -vE "^$P7F_ORCH:" | grep -vE ':[0-9]+:[[:space:]]*//' || true)
if [[ -n "$p7f_rm_copies" ]]; then
    fail "composer-p7-followup" $'the Reduce Motion sentence is duplicated instead of shared:\n'"$p7f_rm_copies"
fi

# (e) This follow-up's claims are about PRESENCE, IDENTITY and ORDER — never
#     elapsed time. Same rule Guards 7/8/9/10 apply to the packets before it.
P7F_TESTS="HueHomeTests/EntertainmentAvailabilityTests.swift"
p7f_wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$P7F_TESTS" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -n "$p7f_wait_hits" ]]; then
    fail "composer-p7-followup" $'timing wait in the availability tests:\n'"$p7f_wait_hits"
fi

# ──────────────────────────────────────────────────────────────
# Guard 12 (composer-hardware-convergence): the hardware pass's four defects
# stay fixed.
#
# Brian's device pass on merged PR #59 found:
#
#  (a) A bridge with an area over bedroom+bathroom and another over
#      bedroom+hallway reported "no compatible Entertainment Area" for the
#      hallway and the bathroom. The selector was right to refuse to guess; the
#      UI was wrong to render that refusal as absence. The fix is a typed
#      decision in which every eligible configuration stays its own candidate —
#      so the tie-break that must never come back is `min(by: id)` inside
#      `decide`. Sorting is display order; it may not choose or hide a target.
#
#  (b) Take Over reported success while Hue Sync kept control. A 2xx on the
#      stop PUT was read as proof the other controller had let go, and
#      `startSession` returning was read as proof a session existed. Both
#      verifications must stay present, and the takeover request ledger must
#      stay disjoint from the other two.
#
#  (c) Effects kept running after a force-close with no recovered row and no
#      Stop. The manifest must be durable BEFORE anything is activated, and the
#      bridge-save action must be reachable without Palette → +N more.
#
#  (d) Scrolling the room wheel onto a room with a running effect threw the
#      customization panel open over it. The room-change handler may not force
#      the tray open.
#
# Behavioural proof lives in the suites; these are the source invariants that
# would let the behaviour quietly regress.

HC_ORCH="HueHome/Core/Network/UnifiedOrchestrator.swift"
HC_VM="HueHome/UI/Studio/StudioViewModel.swift"
HC_VIEW="HueHome/UI/Studio/StudioView.swift"
HC_SELECTOR="HueHome/Core/Network/EntertainmentConfigManager.swift"

# (a) The decision exists, and never breaks a tie by lowest id.
for sym in 'static func decide(' 'case choiceRequired(' 'struct ExactAreaCandidate'; do
    if ! grep -q "$sym" "$HC_SELECTOR"; then
        fail "composer-hardware-convergence" "'$sym' is missing from $HC_SELECTOR — the exact-target decision collapsed back into an optional"
    fi
done

hc_decide_body=$(awk '/static func decide\(/,/^    }$/' "$HC_SELECTOR" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_decide_body" | grep -qE 'min\(by:|\.min \{|\.first \{'; then
    fail "composer-hardware-convergence" $'decide() breaks a tie instead of escalating it — identical light sets must stay separate candidates:\n'"$(echo "$hc_decide_body" | grep -nE 'min\(by:|\.min \{|\.first \{')"
fi

for sym in 'case choiceRequired(' 'case staleSelection' 'case unreadableBridge' \
           'case noCompatiblePlan' 'case ambiguousOwnership' 'func exactTargetDecision('; do
    if ! grep -q "$sym" "$HC_ORCH"; then
        fail "composer-hardware-convergence" "'$sym' is missing from $HC_ORCH — a named outcome was folded back into another"
    fi
done

# The chooser is target fidelity only. It must never mint a consent token.
hc_choice_body=$(awk '/func confirmAreaChoice\(/,/^    }$/' "$HC_VM" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_choice_body" | grep -qE 'EntertainmentConsent\(|consumedEntertainmentConsents|consumedForeignTakeoverRequests'; then
    fail "composer-hardware-convergence" "confirmAreaChoice mints or spends a consent token — choosing WHERE is not agreeing to replace anyone"
fi

# (b) Verification present, and the three ledgers stay disjoint.
for sym in 'func hasStartedSession('; do
    if ! grep -q "$sym" "HueHome/Core/Network/HueEntertainmentClient.swift"; then
        fail "composer-hardware-convergence" "'$sym' is missing — 'startSession returned' would again be treated as proof a session exists"
    fi
done
if ! grep -q 'consumedForeignTakeoverRequests' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the foreign-takeover request ledger is missing from $HC_ORCH"
fi

hc_takeover_body=$(awk '/func resolveForeignTakeover\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
hc_activity_reads=$(echo "$hc_takeover_body" | grep -cE 'entertainmentActivity\(onBridge:' || echo 0)
if [[ "$hc_activity_reads" -lt 2 ]]; then
    fail "composer-hardware-convergence" "resolveForeignTakeover reads bridge activity $hc_activity_reads time(s): it must read once BEFORE the stop and again AFTER it — sending a stop is not proof of release"
fi

# One answer may not spend another question's token.
hc_ledger_mix=$(grep -nE '(consumedForeignTakeoverRequests.*consumedStudioHandoffRequests|consumedStudioHandoffRequests.*consumedForeignTakeoverRequests|consumedForeignTakeoverRequests.*consumedEntertainmentConsents|consumedEntertainmentConsents.*consumedForeignTakeoverRequests)' \
    "$HC_ORCH" 2>/dev/null | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$hc_ledger_mix" ]]; then
    fail "composer-hardware-convergence" $'two consent ledgers are used on one line — a token spendable by the wrong question is not a token:\n'"$hc_ledger_mix"
fi

# (c) Durable before running, and reachable outside Palette → More.
if ! grep -q 'func activate(manifest:' "HueHome/Core/Network/BridgeAnimationEngine.swift"; then
    fail "composer-hardware-convergence" "BridgeAnimationEngine.activate is missing — upload would again start the chain before the manifest is durable"
fi
hc_upload_body=$(awk '/func upload\(/,/^    }$/' "HueHome/Core/Network/BridgeAnimationEngine.swift" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_upload_body" | grep -q 'setSensorStatus'; then
    fail "composer-hardware-convergence" "upload() starts the chain itself — resources would run before the manifest that names them is on disk"
fi
if ! grep -q 'func saveActiveLookToBridge(' "$HC_VM"; then
    fail "composer-hardware-convergence" "the first-class bridge-save action is missing from $HC_VM"
fi
hc_save_entry=$(grep -rln 'saveActiveLookToBridge' HueHome/UI 2>/dev/null \
    | grep -v 'StudioViewModel.swift' || true)
if [[ -z "$hc_save_entry" ]]; then
    fail "composer-hardware-convergence" "no UI surface invokes saveActiveLookToBridge — the bridge save would be reachable only through Palette → More again"
fi

# (d) Landing on a room may not force the effect panel open over the wheel.
if ! grep -q 'static let collapsedOnRoomChange = true' "$HC_VIEW"; then
    fail "composer-hardware-convergence" "the room-change collapse rule is missing or inverted in $HC_VIEW — the tray would cover the room wheel mid-scroll again"
fi
hc_roomchange=$(awk '/onChange\(of: vm.selectedRoom\?.id\)/,/^        }$/' "$HC_VIEW" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_roomchange" | grep -qE 'isMixerCollapsed = false'; then
    fail "composer-hardware-convergence" "the room-change handler forces the mixer open — that is the selector collision"
fi

# (e) Instrumentation may only record what was observed.
#
# The first version recorded BOTH "remained active" and "reacquired the same
# configuration" from one post-stop read. Without ever seeing an inactive
# state, a reacquisition is a transition nobody watched — and an instrument
# that invents transitions sends the next device pass debugging a fiction.
hc_remained_body=$(awk '/if after.foreign.contains\(foreignConfigID\)/,/^        }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_remained_body" | grep -q 'foreignConfigurationReacquiredSameConfig'; then
    fail "composer-hardware-convergence" "the 'still active' branch claims a reacquisition it never observed — no inactive state was seen there"
fi

# Ownership publication is recorded at the commit, and nowhere else.
hc_publish_sites=$(grep -cE 'noteTakeoverEvent\(\.ownershipPublished' "$HC_ORCH" 2>/dev/null || echo 0)
if [[ "$hc_publish_sites" -ne 1 ]]; then
    fail "composer-hardware-convergence" "expected exactly 1 ownershipPublished emission (at the commit), found $hc_publish_sites"
fi
hc_commit_body=$(awk '/func commitEntertainment\(/,/^    }$/' "$HC_ORCH" 2>/dev/null || true)
if ! echo "$hc_commit_body" | grep -q 'ownershipPublished'; then
    fail "composer-hardware-convergence" "commitEntertainment does not record ownershipPublished — the event would drift from the moment ownership becomes real"
fi

# (f) An explicit save may never become app-driven playback.
if ! grep -q 'func saveLookToBridge(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the strict bridge-save entry point is missing from $HC_ORCH"
fi
if ! grep -q 'func attemptBridgeStoredSave(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the shared bridge-save core is gone — the save and ordinary-play paths would drift apart again"
fi
# Round 4: the save is TRANSACTIONAL. saveLookToBridge may never re-enter
# startCompositionMode — its head replaces the room's current look (the
# generation bump invalidates the running runtime), so a save that failed
# there had already stopped the look it was supposed to save.
hc_save_body=$(awk '/func saveLookToBridge\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_save_body" | grep -q 'startCompositionMode('; then
    fail "composer-hardware-convergence" "saveLookToBridge calls startCompositionMode — a failed save would invalidate the running look before the refusal"
fi
# The shared save-outcome mailbox stays dead (round 3). A single slot read
# across suspension points is how one save's Stop button ended up pointed at
# another save's manifest.
if grep -rq 'lastBridgeSaveOutcome' HueHome/; then
    fail "composer-hardware-convergence" "lastBridgeSaveOutcome is back — overlapping saves would read each other's outcome again"
fi
hc_vm_save=$(awk '/func saveActiveLookToBridge\(/,/^    }$/' "$HC_VM" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_vm_save" | grep -q 'startCompositionMode('; then
    fail "composer-hardware-convergence" "the first-class save calls startCompositionMode directly — its upload catch falls back to app-driven REST, which would show a 'Saved' sheet for a look that was never saved"
fi

# (g) A saved-but-not-running look must be removable immediately.
if ! grep -q 'func stopSavedBridgeLook(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the immediate exact Stop for a saved look is missing from $HC_ORCH"
fi
if ! grep -q 'stoppableManifestID' "$HC_VM"; then
    fail "composer-hardware-convergence" "the save result no longer carries a manifest to stop — resources would exist with no way to remove them before a relaunch"
fi

# (h) The destructive sweep may not pick a bridge for the user.
hc_settings="HueHome/UI/Settings/SettingsView.swift"
if ! grep -q 'enum CleanBridgeTarget' "$hc_settings"; then
    fail "composer-hardware-convergence" "CleanBridgeTarget is missing — bridge selection for a destructive sweep would be inline and unprovable"
fi
hc_arbitrary=$(grep -nE 'registeredBridgeIDs\.first|clients\.values\.first|HueAPIClient\.shared' "$hc_settings" 2>/dev/null \
    | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$hc_arbitrary" ]]; then
    fail "composer-hardware-convergence" $'Clean Bridge Resources picks a bridge arbitrarily — lowest-sorting id is not an answer to "which bridge are you about to wipe?":\n'"$hc_arbitrary"
fi
# (h2, round 3) The OPEN destructive dialog may not consult the live
# resolution. cleanBridgeTargetID re-resolves from the current registry; with
# bridge B chosen and lost mid-dialog, one remaining bridge auto-selects and
# the dialog silently retargets. Only the frozen id may appear from the first
# confirmationDialog to the end of the sweep's message.
hc_dialogs=$(awk '/confirmationDialog\(/,/other bridges aren.t touched/' "$hc_settings" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_dialogs" | grep -q 'cleanBridgeTargetID'; then
    fail "composer-hardware-convergence" "a Clean Bridge confirmation dialog reads the LIVE cleanBridgeTargetID — an open destructive dialog must speak only about its frozen id"
fi
if ! grep -q 'cleanBridgeFrozenID' "$hc_settings"; then
    fail "composer-hardware-convergence" "the frozen cleanup identity is gone — the confirmation would re-resolve its target from live state again"
fi

# (i, round 3) Every Entertainment commit goes through the final
# verification. Exactly two lowercase call-shaped occurrences may exist: the
# definition and the one call inside verifyAndCommitEntertainment. (The
# wrapper's own name contains a capital C and does not match.)
hc_commit_calls=$(grep -c 'commitEntertainment(' "$HC_ORCH" 2>/dev/null || echo 0)
if [[ "$hc_commit_calls" -ne 2 ]]; then
    fail "composer-hardware-convergence" "expected exactly 2 'commitEntertainment(' occurrences (definition + the verified call), found $hc_commit_calls — an unverified commit path is growing back"
fi
if ! grep -q 'func verifyAndCommitEntertainment(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "verifyAndCommitEntertainment is missing — commits would no longer be preceded by the final fresh-read + session-health verification"
fi

# (j, round 4c) Bridge-stored cleanup is exact identity, never room-id-only.
# The ownership ledger (bridge + room → manifest ids) is the sole destructive
# proof, one shared withdraw rule serves both the save failures and the exact
# Stop, and the round-4b room-id-only clearing may not grow back.
if grep -rq 'clearStaleBridgeStoredClaims' HueHome/; then
    fail "composer-hardware-convergence" "clearStaleBridgeStoredClaims is back — room-id-only clearing erases another bridge's same-room-id claims"
fi
if ! grep -q 'bridgeStoredChainOwnership' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the exact bridge-stored ownership ledger is gone — destructive predecessor proof would fall back to the roomID-keyed transport map"
fi
if ! grep -q 'private func withdrawDestroyedBridgeStoredClaims(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "withdrawDestroyedBridgeStoredClaims is missing — save and stop cleanup would diverge again"
fi
hc_stop_body=$(awk '/func stopSavedBridgeLook\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if ! echo "$hc_stop_body" | grep -q 'withdrawDestroyedBridgeStoredClaims('; then
    fail "composer-hardware-convergence" "stopSavedBridgeLook no longer routes through the shared exact withdraw — stopping bridge B's manifest could unlabel bridge A's same-room-id chain"
fi
if echo "$hc_save_body" | grep -q 'hadBridgeStoredClaim'; then
    fail "composer-hardware-convergence" "saveLookToBridge reads the room-id-only transport claim as ownership proof again — bridge A's claim must never lend destructive authority to a save on bridge B"
fi

# (k, round 4d) The exact-key rekey must not be undone at the stop handoff:
# a bridge-attributed Now Playing entry keeps its bridge identity all the way
# to Studio, and removed-group teardown matches recorded bridge + room —
# never bare group ids against bridge-qualified presentation keys.
if ! grep -q 'struct LiveEffectStopTarget' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "LiveEffectStopTarget is gone — the stop handler would fall back to a bare room id and fail closed under a room-id collision, stopping neither bridge's look"
fi
if ! grep -q 'var studioStopHandler: (@MainActor (LiveEffectStopTarget) async -> Void)?' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "studioStopHandler no longer carries the exact bridge+room target"
fi
hc_entry_stop=$(awk '/func requestNowPlayingStop\(_ entry:/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if ! echo "$hc_entry_stop" | grep -q 'bridgeID: bridgeID'; then
    fail "composer-hardware-convergence" "requestNowPlayingStop(_ entry:) downgrades attributed entries to the roomID-only overload — tapping either exact Dashboard row under a collision would stop neither"
fi
hc_removed_groups=$(awk '/func stopEffectsForRemovedGroups\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if echo "$hc_removed_groups" | grep -qE 'entry\.id|\$0\.id'; then
    fail "composer-hardware-convergence" "stopEffectsForRemovedGroups compares presentation keys — bridge-qualified live ids match no bare group id, so doomed effects would survive removal"
fi
if ! echo "$hc_removed_groups" | grep -q 'RemovedGroupIdentity'; then
    fail "composer-hardware-convergence" "stopEffectsForRemovedGroups lost its exact-identity input"
fi
hc_removed_ids=$(grep -c 'RemovedGroupIdentity(bridgeID:' "$HC_ORCH" 2>/dev/null || echo 0)
if [[ "$hc_removed_ids" -lt 3 ]]; then
    fail "composer-hardware-convergence" "expected bridge removal + room delete + zone delete to pass exact RemovedGroupIdentity values (>=3 sites), found $hc_removed_ids"
fi

# (l, round 4e) The LIVE runtime authority is exactly keyed. Rounds 4c/4d
# made the presentation and the destructive bridge-stored cleanup exact while
# the real playback runtime stayed room-id-keyed: the second same-room-id
# start silently overwrote the first bridge's runtime, and an exact stop of
# bridge A could invalidate bridge B's generation, evict B from the
# scheduler, or tear down B's Entertainment session picked by dictionary
# order. These pins keep the runtime authority — not just the rows — keyed
# by CompositionPlaybackKey.
if ! grep -q 'struct CompositionPlaybackKey' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "CompositionPlaybackKey is gone — the runtime authority would fall back to bare room ids"
fi
for sym in 'compositionGenerations: \[CompositionPlaybackKey: Int\]' \
           'compositionRuntimes: \[CompositionPlaybackKey: CompositionRuntime\]' \
           'compositionOrder: \[CompositionPlaybackKey\]' \
           'compositionTransportClaims: \[CompositionPlaybackKey: CompositionTransport\]'; do
    if ! grep -qE "$sym" "$HC_ORCH"; then
        fail "composer-hardware-convergence" "'$sym' is missing — a runtime structure lost its exact playback key"
    fi
done
hc_bare_keys=$(grep -nE 'compositionGenerations: \[String:|compositionRuntimes: \[String:|compositionOrder: \[String\]' "$HC_ORCH" 2>/dev/null \
    | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$hc_bare_keys" ]]; then
    fail "composer-hardware-convergence" $'a composition runtime structure is keyed by bare room id again:\n'"$hc_bare_keys"
fi
hc_stop_comp_body=$(awk '/func stopCompositionMode\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
hc_stop_room_keyed=$(echo "$hc_stop_comp_body" | grep -nE 'compositionRuntimes\.removeValue\(forKey: roomID\)|compositionGenerations\[roomID\]|compositionEntRoomByBridge\.first\(where:' || true)
if [[ -n "$hc_stop_room_keyed" ]]; then
    fail "composer-hardware-convergence" $'stopCompositionMode mutates by bare room id or picks an Entertainment bridge by dictionary order — an exact stop of one bridge would destroy the other bridge\047s same-room-id runtime:\n'"$hc_stop_room_keyed"
fi
if ! echo "$hc_stop_comp_body" | grep -q 'compositionEntRoomByBridge\[entBridgeKey\] == roomID'; then
    fail "composer-hardware-convergence" "stopCompositionMode no longer verifies the CALLER's bridge owns the room before Entertainment teardown"
fi
if ! echo "$hc_stop_comp_body" | grep -q 'removeCompositionTransportClaim('; then
    fail "composer-hardware-convergence" "stopCompositionMode does not withdraw the exact transport claim — another bridge's same-room-id claim would fall with it"
fi
if ! grep -q 'func recomputeCompositionTransportAggregate(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the transport aggregate recompute is gone — the room-only map would become writable authority again"
fi
# An inert saved-not-confirmed chain may never create a transport claim.
hc_snc_arms=$(awk '/case \.savedNotConfirmedRunning/,/return \./' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
hc_snc_claims=$(echo "$hc_snc_arms" | grep -nE 'setCompositionTransportClaim\(|compositionTransportByRoom\[[^]]*\][[:space:]]*=' || true)
if [[ -n "$hc_snc_claims" ]]; then
    fail "composer-hardware-convergence" $'a savedNotConfirmedRunning arm writes a transport claim — an inert chain is not the room\047s look:\n'"$hc_snc_claims"
fi
# SSE suppression is bridge+room exact — never a rebuilt room-id set.
if ! grep -q 'func isAppDrivenGroup(bridgeID:' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "the exact SSE-suppression predicate is missing — suppression would conflate bridges sharing a room id"
fi
hc_sse_room_set=$(grep -nE 'appDrivenGroupIDs|compositionRuntimes\.keys\.map\(\\?\.roomID\)' "$HC_ORCH" 2>/dev/null \
    | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$hc_sse_room_set" ]]; then
    fail "composer-hardware-convergence" $'a room-id-only app-driven suppression set is back — bridge A\047s composition would suppress bridge B\047s legitimate SSE:\n'"$hc_sse_room_set"
fi
hc_sse_body=$(awk '/func applySSEEvent\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if ! echo "$hc_sse_body" | grep -q 'isAppDrivenGroup(bridgeID: bridgeID'; then
    fail "composer-hardware-convergence" "applySSEEvent does not pass the event's bridge into the suppression check"
fi

# No timing waits in the suites that carry this slice's behaviour.
HC_TESTS=(
    "HueHomeTests/MultiBridgeRoutingTests.swift"
    "HueHomeTests/EntertainmentAvailabilityTests.swift"
    "HueHomeTests/BridgeAnimationCorrectnessTests.swift"
)
for f in "${HC_TESTS[@]}"; do
    [[ -f "$f" ]] || continue
    hc_wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$hc_wait_hits" ]]; then
        fail "composer-hardware-convergence" $'timing wait in a hardware-convergence suite: '"$f"$':\n'"$hc_wait_hits"
    fi
done

# ──────────────────────────────────────────────────────────────

if [[ $FAILURES -gt 0 ]]; then
    echo "hardening_guards: $FAILURES guard(s) failed." >&2
    exit 1
fi
echo "hardening_guards: all guards passed."
