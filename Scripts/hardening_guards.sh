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
#              SSE suppression. Round 4f (m): saved-look Stop truth — the
#              withdraw takes caller-captured ownership evidence (a nil
#              ledger key alone may not remove a live publication),
#              stopSavedBridgeLook captures that evidence before retirement
#              destroys it, Studio consumes the typed outcome and
#              revalidates the presentation fence before every row/box
#              removal, and invalid-fence copy stays neutral (no emptiness
#              claim, no unproven active-playback claim). Round 4g (n): the
#              app-driven engine runtime (loop task, live param box, Studio
#              REST scope) is keyed by BRIDGE — the global slots whose
#              teardown let a start on bridge 2 stop bridge 1's stream may
#              not return, apply's teardown loops carry the same-bridge
#              predicate, and the app-driven stop verifies exact bridge+room
#              ownership before cancelling anything.
#  13. build-47 device finding 3 / checklist row 36 — the Studio
#              customization host is ONE CONTINUOUS SURFACE: no detached
#              sheet from the host, the panel or any Slice 2 instrument
#              surface, no disclosure gate in the host, exactly one vertical
#              ScrollView in the host, and a live beat auto-anchor.
#  14. Slice 2 R1 — the 3 Hz flash ceiling is a REALIZED-FRAME invariant:
#              one pure BeatMath.FlashSafety API, plans that floor a whole
#              safe cycle before splitting it, ENT loops that sleep the shared
#              frame quantum, cap every beat lock at the realizable ceiling,
#              never touch the raw beatsPerCycle, and delay their onsets
#              through a ledger shared per BRIDGE that is never dropped.
#  15. Slice 2 R2 — ONE board availability funnel: both StudioBoardView
#              renderers (controls and colour) resolve through
#              StudioBoardAvailability, the pre-funnel per-view verdicts stay
#              gone, and the colour context reads the board's own snapshot.
#              Round 2: Hidden renders NOTHING (both renderers gate on
#              rendersControl), the funnel is asked in its fail-closed
#              strategy-qualified form, colour's dead editor keeps both floors
#              (no-op onApply + isInteractive), the knob/fader keeps both of
#              its interactivity guards, and the "checking what these lights
#              support" state can be left — the warm path fetches lights on a
#              cold cache and the arriving inventory is an observable
#              generation the snapshot depends on.

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
else
    # COUNTING IS NOT ORDERING. The failure text above promises "once BEFORE
    # the stop and again AFTER it", and a count of two satisfies it however
    # the reads are placed — cache the pre-stop read into a snapshot and take
    # BOTH reads after the stop, and the count is still 2 while the "was it
    # released?" question is answered by a value fetched before anything was
    # asked to release. Pinned positionally, the same way 14's
    # admit -> send -> commit chain is.
    hc_stop_at=$(echo "$hc_takeover_body" | grep -nF '"action": "stop"' | head -1 | cut -d: -f1)
    hc_read_first=$(echo "$hc_takeover_body" | grep -nE 'entertainmentActivity\(onBridge:' | head -1 | cut -d: -f1)
    hc_read_last=$(echo "$hc_takeover_body" | grep -nE 'entertainmentActivity\(onBridge:' | tail -1 | cut -d: -f1)
    if [[ -z "$hc_stop_at" ]]; then
        fail "composer-hardware-convergence" "resolveForeignTakeover no longer sends the stop PUT (body: [\"action\": \"stop\"]) — the two activity reads would straddle nothing"
    else
        if [[ "$hc_read_first" -ge "$hc_stop_at" ]]; then
            fail "composer-hardware-convergence" "resolveForeignTakeover's FIRST bridge-activity read is at body line $hc_read_first, at or after the stop at $hc_stop_at — nothing establishes who owned the area before the stop was sent"
        fi
        if [[ "$hc_read_last" -le "$hc_stop_at" ]]; then
            fail "composer-hardware-convergence" "resolveForeignTakeover's LAST bridge-activity read is at body line $hc_read_last, at or before the stop at $hc_stop_at — a release verified from a snapshot taken BEFORE the stop is not a verification"
        fi
    fi
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
# Track A C4 renamed the rule's vocabulary (`collapsedOnRoomChange = true` →
# `modeOnRoomChange = .decks`); Slice 2 made it a pure POLICY FUNCTION so an
# active-target switch can keep an already-open console (spec §14.3) — but
# the defect-facing half of the rule is unchanged: from the DECKS, arriving
# anywhere must stay on the decks. The guard tracks that half: the function
# must exist, and its body may open customization only when the CURRENT mode
# is already customization.
if ! grep -qE 'static func modeOnRoomChange\(current: StudioRegionMode' "$HC_VIEW"; then
    fail "composer-hardware-convergence" "the room-change rule is missing or inverted in $HC_VIEW — the tray would cover the room wheel mid-scroll again"
fi
hc_room_rule=$(awk '/static func modeOnRoomChange\(/,/^    }/' "$HC_VIEW")
if ! echo "$hc_room_rule" | grep -q 'current == .customization'; then
    fail "composer-hardware-convergence" "modeOnRoomChange no longer conditions on the CURRENT mode — a room change from the decks could auto-open the tray over the wheel again"
fi
# Conditioning alone is not the rule. A body that mentions the condition and
# then returns .customization on BOTH branches reinstates the exact defect, so
# the non-customization outcome must be present in the body as well.
if ! echo "$hc_room_rule" | grep -qF '.decks'; then
    fail "composer-hardware-convergence" "modeOnRoomChange never returns .decks — arriving on a room from the decks would open the tray over the wheel again"
fi
# Neither is the PAIR of substrings the rule. The two checks above are both
# satisfied by `(current == .customization || newTargetRunsALook) ? .customization : .decks`
# — one character's difference, and arriving on a running room from the decks
# auto-opens the tray over the wheel again with the guards green. So the
# CONJUNCTION itself is pinned: the current mode and the target's state must
# BOTH hold on the branch that opens customization. The body is joined and
# comment-stripped first, so a wrapped expression still matches and a commented
# copy of the right shape cannot stand in for the real one.
#
# Two corrections to the first version of this check:
#   * it pinned ONE operand ORDER (`current == .customization && …`), so the
#     equivalent `(newTargetRunsALook && current == .customization)` failed a
#     guard it satisfies. A guard that rejects a correct refactor gets deleted,
#     and then nothing pins the conjunction at all. The condition is now
#     extracted and asked three order-free questions instead.
#   * `grep -vE '^[[:space:]]*//'` drops only comment-ONLY lines, so a TRAILING
#     `// … && …` comment could still smuggle the required shape onto a line
#     whose real code is a disjunction. Comments are now truncated, not just
#     whole-line filtered.
hc_room_expr=$(echo "$hc_room_rule" | sed -E 's@//.*$@@' | tr '\n' ' ' | tr -s ' ')
# The condition is what stands in front of the ternary that decides the mode —
# the operands the customization branch actually rests on. ERE has no lazy
# quantifier, so the prefix is taken greedily and then trimmed back past the
# last `{` / `return`, which keeps an unrelated earlier statement's operators
# out of the disjunction check below.
hc_room_cond=$(echo "$hc_room_expr" | sed -nE 's@^(.*)[?] \.customization : \.decks.*$@\1@p')
hc_room_cond="${hc_room_cond##*\{}"
hc_room_cond="${hc_room_cond##*return }"
if [[ -z "${hc_room_cond//[[:space:]]/}" ]] \
    || ! echo "$hc_room_cond" | grep -qF 'current == .customization' \
    || ! echo "$hc_room_cond" | grep -qF '&&' \
    || echo "$hc_room_cond" | grep -qF '||'; then
    fail "composer-hardware-convergence" "modeOnRoomChange no longer opens customization only when the CURRENT mode is customization AND the new target runs a look — a disjunction there re-opens the tray over the wheel on arrival"
fi
# The anchor tracks the handler, not one spelling of its key: Track A C1
# re-keyed it from `vm.selectedRoom?.id` to the exact StudioSelectionKey, and a
# pattern pinned to the old spelling would have matched nothing and passed
# vacuously — a guard that cannot fail is not a guard.
# C4 moved this handler into the same-file StudioRegionWiring modifier, so the
# awk end-anchor is indentation-agnostic now — a range pinned to one nesting
# depth would have matched nothing and passed vacuously.
hc_roomchange=$(awk '/onChange\(of: vm.selectedRoom/,/^[[:space:]]*}$/' "$HC_VIEW" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if [[ -z "$hc_roomchange" ]]; then
    fail "composer-hardware-convergence" "the selectedRoom onChange handler is gone from $HC_VIEW — the room-change rule is unenforceable"
fi
if echo "$hc_roomchange" | grep -qE 'isMixerCollapsed = false|regionMode = \.customization'; then
    fail "composer-hardware-convergence" "the room-change handler opens the customization region — that is the selector collision"
fi

# (d2, Track A C1) Selection-keyed side effects stay EXACT. Two bridges can
# expose the same Hue room id, so a bare-id key means the coverage task never
# refires and Deck 0 labels bridge A's capabilities as bridge B's room. The
# per-BRIDGE entertainment sweep at the same site is deliberately excluded — it
# is keyed by bridgeID on purpose.
hc_bare_selection=$(grep -nE '\.(task|onChange)\(of: vm\.selectedRoom\?\.id\)|\.task\(id: vm\.selectedRoom\?\.id\)' "$HC_VIEW" 2>/dev/null \
    | grep -vE ':[[:space:]]*//' || true)
if [[ -n "$hc_bare_selection" ]]; then
    fail "composer-hardware-convergence" $'a Studio selection side effect is keyed by bare room id again — it will not refire between two bridges sharing a room id:\n'"$hc_bare_selection"
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

# (m, round 4f) Saved-look Stop truth. `retireManifest` subtracts the
# ownership ledger BEFORE the shared withdraw runs, so a nil ledger key
# cannot distinguish "this chain's ownership just emptied" from "this chain
# never ran" — and removing a live publication on a merely-nil key is how an
# inert manifest's Remove unpublished the room's still-running REST look.
# The withdraw therefore takes caller-captured evidence and a caller-verified
# newer-owner fence; the stop captures both before retirement; Studio
# consumes the typed outcome and revalidates the fence at the moment it
# mutates presentation state; and invalid-fence copy claims neither
# emptiness nor active playback.
hc_withdraw_body=$(awk '/private func withdrawDestroyedBridgeStoredClaims\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if ! echo "$hc_withdraw_body" | grep -q 'ownershipEvidence: Set<UUID>'; then
    fail "composer-hardware-convergence" "withdrawDestroyedBridgeStoredClaims lost its required ownershipEvidence — destructive ownership would be inferred from the post-cleanup ledger again"
fi
if echo "$hc_withdraw_body" | grep -qE 'ownershipEvidence: Set<UUID>[[:space:]]*=|presentationFenceHeld: Bool[[:space:]]*='; then
    fail "composer-hardware-convergence" "the withdraw's evidence or fence parameter grew a default — every caller must capture and pass its own proof"
fi
if ! echo "$hc_withdraw_body" | grep -q 'presentationFenceHeld: Bool'; then
    fail "composer-hardware-convergence" "withdrawDestroyedBridgeStoredClaims lost its presentation fence — a newer playback's publication could be withdrawn by an old look's cleanup"
fi
if ! echo "$hc_withdraw_body" | grep -q 'destroyedWereRunningOwners'; then
    fail "composer-hardware-convergence" "the withdraw no longer derives running ownership from caller evidence — an inert manifest's Remove could unpublish the room's live look"
fi
if echo "$hc_withdraw_body" | grep -qE '^[[:space:]]*if bridgeStoredChainOwnership\[key\] == nil \{'; then
    fail "composer-hardware-convergence" "the withdraw removes on a merely-nil ownership key again — nil cannot distinguish an emptied running chain from a chain that never ran"
fi
hc_withdraw_removes=$(echo "$hc_withdraw_body" | grep -c 'removeActiveEffect(' || true)
if [[ "$hc_withdraw_removes" -ne 1 ]]; then
    fail "composer-hardware-convergence" "expected exactly one gated removeActiveEffect in the withdraw, found $hc_withdraw_removes — publication removal must sit behind the evidence and fence gates"
fi
if ! echo "$hc_withdraw_body" | grep -q 'if presentationFenceHeld {'; then
    fail "composer-hardware-convergence" "the withdraw's publication removal is not fenced — a newer playback that took the key mid-suspension would lose its Now Playing row"
fi
# The stop must capture its evidence BEFORE the bridge await and BEFORE
# retirement destroys it (hc_stop_body extracted in sub-check j).
hc_stop_capture_line=$(echo "$hc_stop_body" | grep -n 'bridgeStoredChainOwnership\[' | head -1 | cut -d: -f1)
hc_stop_await_line=$(echo "$hc_stop_body" | grep -n 'bridgeAnimationEngine\.stop(' | head -1 | cut -d: -f1)
hc_stop_retire_line=$(echo "$hc_stop_body" | grep -n 'retireManifest(' | head -1 | cut -d: -f1)
if [[ -z "$hc_stop_capture_line" || -z "$hc_stop_await_line" || -z "$hc_stop_retire_line" ]] \
    || [[ "$hc_stop_capture_line" -ge "$hc_stop_await_line" ]] \
    || [[ "$hc_stop_capture_line" -ge "$hc_stop_retire_line" ]]; then
    fail "composer-hardware-convergence" "stopSavedBridgeLook no longer captures its ownership evidence before the bridge await and the retirement — after retireManifest the ledger cannot say whether the stopped chain was running"
fi
if ! echo "$hc_stop_body" | grep -q 'SavedLookStopOutcome'; then
    fail "composer-hardware-convergence" "stopSavedBridgeLook no longer returns the typed outcome — Studio cannot tell an inert removal from a running-look withdrawal"
fi
if ! echo "$hc_stop_body" | grep -q 'SavedLookPresentationFence'; then
    fail "composer-hardware-convergence" "stopSavedBridgeLook mints no presentation fence — the VM would mutate rows and boxes on an unverifiable authorization"
fi
if ! grep -q 'func presentationFenceHolds(' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "presentationFenceHolds is gone — a returned authorization could not be revalidated after the orchestrator→VM continuation gap"
fi
# Studio's appliers: typed consumption, fence revalidation before EVERY
# row/box removal, no room-only cleanup, and apply-time copy truth.
hc_apply_stop=$(awk '/func applySavedLookStopOutcome\(/,/^    }$/' "$HC_VM" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
hc_apply_save=$(awk '/func applyBridgeSaveOutcome\(/,/^    }$/' "$HC_VM" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if [[ -z "$hc_apply_stop" || -z "$hc_apply_save" ]]; then
    fail "composer-hardware-convergence" "the factored VM outcome appliers are gone — the continuation-gap race would be untestable and the fence unverified at mutation time"
fi
if ! echo "$hc_apply_stop" | grep -q 'case .removed'; then
    fail "composer-hardware-convergence" "Studio no longer switches on the typed saved-look Stop outcome"
fi
for body_name in hc_apply_stop hc_apply_save; do
    body=${!body_name}
    fence_line=$(echo "$body" | grep -n 'presentationFenceHolds(' | head -1 | cut -d: -f1)
    row_line=$(echo "$body" | grep -n 'runningEffects\.removeValue' | head -1 | cut -d: -f1)
    box_line=$(echo "$body" | grep -n 'activeCompositionBoxes\.removeValue' | head -1 | cut -d: -f1)
    if [[ -z "$fence_line" || -z "$row_line" || -z "$box_line" ]] \
        || [[ "$fence_line" -ge "$row_line" ]] || [[ "$fence_line" -ge "$box_line" ]]; then
        fail "composer-hardware-convergence" "$body_name mutates a running row or composition box without first revalidating the presentation fence — a look that started after the outcome returned would be erased"
    fi
    if echo "$body" | grep -qE 'removeActiveEffect\(roomID:|runningEffect\(forRoomID:'; then
        fail "composer-hardware-convergence" "$body_name uses room-id-only cleanup — presentation removal must be exact bridge+room identity"
    fi
done
# Copy truth: the empty-room sentences may be chosen only behind the
# apply-time fence check, and the invalid-fence branch may use only the
# neutral superseded-state wording. The outcome itself may not freeze an
# emptiness claim.
hc_save_fence_line=$(echo "$hc_apply_save" | grep -n 'fenceValid' | head -1 | cut -d: -f1)
hc_save_empty_line=$(echo "$hc_apply_save" | grep -nE 'BridgeSaveCopy\.(previousLookRemovedSaveFailed|savedNotConfirmedPreviousLookRemoved)$' | head -1 | cut -d: -f1)
if [[ -z "$hc_save_fence_line" || -z "$hc_save_empty_line" ]] \
    || [[ "$hc_save_fence_line" -ge "$hc_save_empty_line" ]]; then
    fail "composer-hardware-convergence" "applyBridgeSaveOutcome selects the empty-room wording without an apply-time fence check — the UI could claim 'nothing is playing' over a newer look's playback"
fi
if ! echo "$hc_apply_save" | grep -q 'previousLookRemovedSaveFailedPlaybackChanged' \
    || ! echo "$hc_apply_save" | grep -q 'savedNotConfirmedPreviousLookRemovedPlaybackChanged'; then
    fail "composer-hardware-convergence" "the neutral superseded-state wording is gone — an invalid fence would have to claim emptiness or playback it cannot prove"
fi
if grep -qE 'case previousLookRemovedSaveFailed\(bridgeID: String, reason' "$HC_ORCH"; then
    fail "composer-hardware-convergence" "previousLookRemovedSaveFailed carries a precomputed reason again — the emptiness claim would be frozen before the continuation gap it cannot see across"
fi

# (n, round 4g) One app-driven engine per BRIDGE. The hardware pass proved
# the defect: the engine task, live param box, and Studio REST scope were
# single global slots, and StudioViewModel.apply stopped every streaming row
# on every bridge before a start — so starting Entertainment on bridge 2
# stopped bridge 1's stream. The per-bridge maps must stay, the dead global
# symbols may not return, the VM's teardown loops must keep their same-bridge
# predicate, and the app-driven stop must keep proving exact bridge+room
# ownership before it cancels or removes anything.
# Slice 2 production wiring strengthened the update path: it must name the
# room as well as the bridge, and the runtime's owning room must match —
# the same exact-ownership proof stopAppDrivenStudioEffect carries.
for sym in 'studioEngineRuntimesByBridge: [String: StudioEngineRuntime]' \
           'studioRestScopesByBridge: [String: RestScope]'; do
    if ! grep -qF "$sym" "$HC_ORCH"; then
        fail "composer-hardware-convergence" "'$sym' is missing from $HC_ORCH — the per-bridge app-driven engine runtime collapsed back toward a global slot"
    fi
done
# The signature claim is SCOPED to updateStudioParams. A file-wide grep for
# 'bridgeID: String?, roomID: String' passes vacuously as soon as any unrelated
# function happens to spell the same pair, so the literal is asserted against
# the extracted body — and the body must also carry the exact-ownership
# predicate stopAppDrivenStudioEffect carries.
hc_update_body=$(awk '/func updateStudioParams\(/,/^    }/' "$HC_ORCH" 2>/dev/null || true)
if [[ -z "$hc_update_body" ]]; then
    fail "composer-hardware-convergence" "updateStudioParams is gone from $HC_ORCH — the live-edit target rule is unenforceable"
fi
if ! echo "$hc_update_body" | grep -qF 'bridgeID: String?, roomID: String'; then
    fail "composer-hardware-convergence" "updateStudioParams no longer names the ROOM alongside the bridge — a live edit could land on a sibling room's engine on the same bridge"
fi
if ! echo "$hc_update_body" | grep -qF 'runtime.roomID == roomID'; then
    fail "composer-hardware-convergence" "updateStudioParams lost its runtime.roomID == roomID guard — a live edit could land on a sibling room's engine on the same bridge"
fi
# The comment filter is ANCHORED to the line-number prefix grep -n emits.
# The unanchored `:[[:space:]]*//` form also matched any line containing a
# `://` — a URL in a trailing comment — so `let activeParamBox = ... // see
# https://…` would have been discarded as "a comment" and passed silently.
hc_global_slots=$(grep -nE 'activeStudioTask|activeParamBox|activeStudioRestScope' "$HC_ORCH" "$HC_VM" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [[ -n "$hc_global_slots" ]]; then
    fail "composer-hardware-convergence" $'a dead global studio slot symbol is back — one bridge\'s start could again destroy another bridge\'s runtime:\n'"$hc_global_slots"
fi
hc_unscoped_ent_loop=$(grep -nE 'in runningEffects where effect\.isEntertainment' "$HC_VM" \
    | grep -v 'rowKey.bridgeID == room.bridgeID' || true)
if [[ -n "$hc_unscoped_ent_loop" ]]; then
    fail "composer-hardware-convergence" $'apply\'s entertainment teardown loop lost its same-bridge predicate — starting on one bridge would stop every bridge\'s stream again:\n'"$hc_unscoped_ent_loop"
fi
hc_bridge_predicates=$(grep -c 'rowKey.bridgeID == room.bridgeID' "$HC_VM" || true)
if [[ "$hc_bridge_predicates" -lt 3 ]]; then
    fail "composer-hardware-convergence" "expected the same-bridge predicate on all three of apply's teardown loops (engine-singleton, entertainment, light-overlap), found $hc_bridge_predicates"
fi
hc_appstop_body=$(awk '/func stopAppDrivenStudioEffect\(/,/^    }$/' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
if ! echo "$hc_appstop_body" | grep -q 'runtime.roomID == roomID'; then
    fail "composer-hardware-convergence" "stopAppDrivenStudioEffect no longer verifies the runtime's owning room before cancelling — a stale stop could kill a newer same-bridge effect's loop"
fi
if ! echo "$hc_appstop_body" | grep -q 'studioEngineRuntimesByBridge\[bid\] == nil'; then
    fail "composer-hardware-convergence" "stopAppDrivenStudioEffect no longer checks for a newer runtime across its settle suspension — a stale stop could tear down a successor's session"
fi

# No timing waits in the suites that carry this slice's behaviour. The
# unified-customization suites (Slice 1 foundation + Slice 2 production
# wiring) express every race as call ordering against the pure fence.
HC_TESTS=(
    "HueHomeTests/MultiBridgeRoutingTests.swift"
    "HueHomeTests/EntertainmentAvailabilityTests.swift"
    "HueHomeTests/BridgeAnimationCorrectnessTests.swift"
    "HueHomeTests/CustomizationIdentityTests.swift"
    "HueHomeTests/CustomizationResolverTests.swift"
    "HueHomeTests/StudioProductionWiringTests.swift"
    "HueHomeTests/PreviewLiveTests.swift"
    "HueHomeTests/InstrumentControlMathTests.swift"
    "HueHomeTests/EffectParameterProfilesTests.swift"
    "HueHomeTests/StudioLookLibraryTests.swift"
    "HueHomeTests/FlashSafetyTests.swift"
    "HueHomeTests/StudioBoardAvailabilityTests.swift"
    "HueHomeTests/StudioPreviewLiveProductionTests.swift"
    "HueHomeTests/StudioLifecycleSerializationTests.swift"
)
for f in "${HC_TESTS[@]}"; do
    # A skipped-because-missing suite is coverage silently dropped: rename or
    # delete a file in this list and the timing-wait ban stops applying to it
    # with the guards still green. Every listed suite exists at HEAD, so a
    # missing one is a fact about the list, not about the run.
    [[ -f "$f" ]] || fail "composer-hardware-convergence" "$f is missing — a suite in the no-timing-wait list was renamed or deleted; update HC_TESTS (and keep the ban on its replacement)"
    hc_wait_hits=$(grep -nE 'Task\.sleep|XCTWaiter|wait\(for:' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    if [[ -n "$hc_wait_hits" ]]; then
        fail "composer-hardware-convergence" $'timing wait in a hardware-convergence suite: '"$f"$':\n'"$hc_wait_hits"
    fi
done

# ──────────────────────────────────────────────────────────────
# Guard 13 (build-47 device finding 3, checklist row 36): the Studio
# customization host is ONE CONTINUOUS SURFACE.
#
# The host scrolled continuously, but its advanced disclosure and "+N MORE"
# presented a detached sheet — and `showAdvanced` was never written `true`
# anywhere, so the inline branch was unreachable and "+N MORE" could only open
# `StudioParamSheet`. Advanced controls now render in the same column as the
# essentials, with no affordance to tap.
#
# These are STRUCTURAL claims the test suite cannot make: on iOS 26 SwiftUI's
# ScrollView is not UIKit-backed, so there is no UIScrollView to count in-process
# and no way to assert "a sheet modifier does not exist" from a render.
R36_HOST="HueHome/UI/Studio/MixerTrayView.swift"
R36_PANEL="HueHome/UI/Composer/CompositionEditorPanel.swift"

# Slice 2 split the one surface across the instrument files: the board, the
# look browser, the shared touch controls, the identity header, the color
# editor and the beat section all render INSIDE the same scrolling column, so
# the no-detached-presentation rule (a) covers them too. Only (a): (b)'s
# `isExpanded` ban stays on the host + panel, because StageColorEditor owns a
# caller-bound `isExpanded` BY DESIGN, and (c)'s one-vertical-ScrollView count
# is a claim about the host alone.
# Slice 3 adds the Composer supporting tier: `ComposerSupportingControls`
# (historical filename ComposerLayerSheet.swift — no sheet lives there any
# more) renders INSIDE each layer's card, so it is on the one-surface path.
R36_COMPOSER_SUPPORT="HueHome/UI/Composer/ComposerLayerSheet.swift"
R36_SURFACES=(
    "$R36_HOST"
    "$R36_PANEL"
    "$R36_COMPOSER_SUPPORT"
    "HueHome/UI/Studio/StudioBoardView.swift"
    "HueHome/UI/Studio/StudioLookBrowserView.swift"
    "HueHome/UI/Components/StageInstrumentControls.swift"
    "HueHome/UI/Studio/StudioIdentityHeader.swift"
    "HueHome/UI/Components/StageColorEditor.swift"
    "HueHome/UI/Components/StageBeatSection.swift"
)

# (a) No detached presentation from any file on this path. `StudioParamSheet`
# stays DEFINED (Track B owns it); `ComposerLayerSheet` and `StageMoreButton`
# were DELETED in Slice 3 (zero call sites) — their tokens stay in the regex
# so a resurrection on this path fails the same way a presentation would.
for f in "${R36_SURFACES[@]}"; do
    [[ -f "$f" ]] || fail "studio-one-surface" "$f is missing — the row-36 rule is unenforceable"
    # Anchored comment filter, as in 14(d): the unanchored `:[[:space:]]*//`
    # form threw away every line containing `://`, so a real presentation with
    # a URL in its trailing comment — `.sheet(isPresented: $x) // see
    # https://example.com` — was read as a comment and passed.
    # `.popover(` is the third detached presentation SwiftUI offers, and on
    # iPhone it renders as a sheet — banning the first two and leaving it out
    # made the rule a naming convention rather than a rule.
    r36_present=$(grep -nE '\.sheet\(|\.fullScreenCover\(|\.popover\(|StudioParamSheet\(|ComposerLayerSheet\(|StageMoreButton\(' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    # ACCEPTED DEBT, anchored so it cannot widen. The Composer panel's harmony
    # swatch editor has shipped as a `.popover(item: $editingSwatch)` since
    # before this rule existed, and rewriting it in place is a Track-B change,
    # not a guard change. Exactly that one binding is exempt, in exactly that
    # one file: any OTHER popover — a different binding, an `isPresented:`
    # form, the same call moved to another surface — still fails.
    if [[ "$f" == "$R36_PANEL" ]]; then
        r36_present=$(echo "$r36_present" | grep -vF '.popover(item: $editingSwatch)' || true)
    fi
    # PERMITTED, anchored so it cannot widen: the Entertainment-area BUILDER
    # (`EntertainmentConfigBuilderView`) is a multi-step creation workflow that
    # POSTs a new bridge resource — a genuine destination, not a place where a
    # control was hidden. Exactly that one `isPresented:` binding is exempt, in
    # exactly that one file; the row that opens it renders inline in the card.
    # Any other sheet here — a different binding, a `.popover(`, the same call
    # moved to the panel — still fails.
    if [[ "$f" == "$R36_COMPOSER_SUPPORT" ]]; then
        r36_present=$(echo "$r36_present" | grep -vF '.sheet(isPresented: $showEntertainmentBuilder)' || true)
    fi
    if [[ -n "$r36_present" ]]; then
        fail "studio-one-surface" $'the customization host presents a detached surface for its controls again — advanced controls must expand in place:\n'"$f"$':\n'"$r36_present"
    fi
done

# (b) The disclosure state may not return. Either spelling reintroduces a gate
# in front of controls that are supposed to be on the page already.
#
# The comment filter is ANCHORED, as in (a) and 14(d): the unanchored
# `:[[:space:]]*//` form discarded every line whose CODE happened to contain
# `: //` — a URL in a trailing comment, a dictionary literal — so a real
# disclosure gate could hide behind one. Two files are grepped here, so grep
# prefixes each hit with `<file>:<line>:` and the anchor has to spell both
# fields; `^[0-9]+:` (the single-file form) would have matched nothing and
# filtered nothing.
r36_state=$(grep -nE 'showAdvanced|showParamSheet|showLayerSheet|isExpanded' "$R36_HOST" "$R36_PANEL" 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' || true)
if [[ -n "$r36_state" ]]; then
    fail "studio-one-surface" $'a disclosure gate is back in the customization host — the advanced controls are meant to be scrolled to, not revealed:\n'"$r36_state"
fi

# (c) Exactly ONE vertical scroll surface in the host. The horizontal badge lane
# and the composer chip scroller are explicitly permitted and excluded by their
# `.horizontal` axis; a second VERTICAL scroller is the nested-scrolling defect
# C5 flattened away.
#
# BOTH spellings count. The pattern used to be `ScrollView\(` alone, which sees
# only the axis-taking form — the trailing-closure `ScrollView { … }` (the
# default vertical axis, and the shorter spelling of the two) was invisible, so
# a second vertical scroller could be nested back in with the count still
# reading 1. `ScrollViewReader {` is not a scroll surface and does not match:
# `[({]` has to follow the word `ScrollView` itself.
# The comment filter is anchored here too — single-file grep, so `^[0-9]+:`.
#
# The `.horizontal` exclusion is ANCHORED TO THE SCROLLVIEW TOKEN, for the same
# reason the comment filters above are anchored. The bare `grep -vE '\.horizontal'`
# discarded any matching line that mentioned the word anywhere — so a brand-new
# VERTICAL scroller whose trailing comment happened to say ".horizontal"
# (`ScrollView {  // not .horizontal`, or `// paired with the .horizontal lane
# below`) was thrown away before it could be counted, and the host could grow a
# second vertical scroll surface with the count still reading 1. Only the axis
# argument of the ScrollView itself excludes: `ScrollView(.horizontal…`.
r36_vertical=$(grep -nE 'ScrollView[[:space:]]*[({]' "$R36_HOST" 2>/dev/null \
    | grep -vE 'ScrollView[[:space:]]*\(\.horizontal' \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
r36_vcount=$(printf '%s' "$r36_vertical" | grep -c . || true)
if [[ "$r36_vcount" -ne 1 ]]; then
    fail "studio-one-surface" $'the host must have exactly ONE vertical ScrollView, found '"$r36_vcount"$':\n'"$r36_vertical"
fi

# (d) The beat auto-anchor must keep targeting the host's real scroll surface —
# the whole point of C5 hoisting the ScrollViewReader out of the inner boxes.
if ! grep -q 'scrollTo("reactionBeatControls"' "$R36_HOST"; then
    fail "studio-one-surface" "the beat auto-anchor is gone from $R36_HOST — enabling a beat source would no longer scroll its controls into view"
fi
if ! grep -q '\.id("reactionBeatControls")' "$R36_PANEL"; then
    fail "studio-one-surface" "the \"reactionBeatControls\" anchor target is gone from $R36_PANEL — the host's scrollTo would resolve to nothing"
fi

# (e) Slice 3: Composer has NO user-facing "Advanced" concept. The literal
# `StageCard(title: "Advanced")` was the last Advanced caption in the app; its
# controls now render in the same card as the essentials. Any string literal
# containing `Advanced` in either Composer file is a regression — a caption, a
# sheet title, an accessibility label — as is the retired symbol.
# Anchored comment filter (two files ⇒ `<file>:<line>:` prefix).
r36_advanced=$(grep -nE '"[^"]*Advanced[^"]*"|ComposerAdvancedControls|advancedControlIDs|advancedCount\(' "$R36_PANEL" "$R36_COMPOSER_SUPPORT" 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' || true)
if [[ -n "$r36_advanced" ]]; then
    fail "studio-one-surface" $'Composer exposes an "Advanced" concept again — supporting controls belong in the layer card, not behind a caption or a sheet:\n'"$r36_advanced"
fi
# The supporting tier must be rendered INSIDE the panel's layer cards (the
# thing that replaced the Advanced card), and the tab subtree may not regain
# the `.id(tab)` split that gave the two tiers different identity lifetimes.
if ! grep -q 'ComposerSupportingControls(vm: vm, orchestrator: orchestrator,' "$R36_PANEL"; then
    fail "studio-one-surface" "$R36_PANEL no longer renders ComposerSupportingControls inside its layer cards — the supporting tier has no surface"
fi
r36_tab_id=$(grep -nE '\.id\(activeCompositionTab\)' "$R36_PANEL" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -n "$r36_tab_id" ]]; then
    fail "studio-one-surface" $'the Composer tab subtree is keyed by `.id(activeCompositionTab)` again — a tab change tears down in-flight exact entry, and the tiers split lifetimes:\n'"$r36_tab_id"
fi
# The migration proof exists and runs: the render test that walks every
# catalog control id per layer/gating state and asserts each one is on the
# page, with no "Advanced" text and no colour popover.
R36_CONVERGENCE_TESTS="HueHomeTests/ComposerConvergenceTests.swift"
[[ -f "$R36_CONVERGENCE_TESTS" ]] \
    || fail "studio-one-surface" "$R36_CONVERGENCE_TESTS is missing — the Advanced-retirement migration has no proof"
grep -q 'ComposerConvergenceTests.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "studio-one-surface" "ComposerConvergenceTests.swift exists but is not in the test target — it never runs"
grep -q 'testEveryFormerAdvancedControlIsStillRendered' "$R36_CONVERGENCE_TESTS" \
    || fail "studio-one-surface" "the per-control migration test is gone from $R36_CONVERGENCE_TESTS"

# ──────────────────────────────────────────────────────────────
# Guard 14 (Slice 2 R1): the 3 Hz flash ceiling is a REALIZED-FRAME invariant.
#
# The old loops clamped a REQUESTED rate and then floored each half of the
# cycle independently against a hard-coded 0.02: `Int(onDuration / 0.02)` and
# `Int(offDuration / 0.02)`. Two independent floors can shorten a safe total
# below 1/3 s, a raw `binding.beatsPerCycle` can multiply an already-legal lock
# past the ceiling, and a per-loop wall clock cannot see the onset another loop
# on the same bridge just realized. Every one of those is invisible to a suite
# that only checks the requested Hz.
#
# The invariant now lives in one pure place (BeatMath.FlashSafety): loops plan
# a whole SAFE TOTAL and split it, sleep the shared frame quantum, cap their
# beat lock at the realizable ceiling, and delay — never skip — an onset
# through a ledger shared per BRIDGE across loop instances.
# ──────────────────────────────────────────────────────────────

HC_BEAT="HueHome/Core/Audio/BeatBinding.swift"
HC_ENT="HueHome/Core/Network/HueEntertainmentClient.swift"
[[ -f "$HC_ENT" ]] || fail "slice2-r1" "$HC_ENT is missing — the transport's delivery answer has no home"

# (a) The pure API exists — as a DECLARATION, not as a mention. A bare
#     whole-file substring grep is satisfied by the prose above each fix, which
#     necessarily names every symbol it explains; deleting `clampedInt` while
#     leaving the paragraph that describes it would have passed. Comment lines
#     are stripped and the match is anchored to a declaration form.
[[ -f "$HC_BEAT" ]] || fail "slice2-r1" "$HC_BEAT is missing — the flash-safety invariant has no home"
hc_beat_code=$(grep -vE '^[[:space:]]*//' "$HC_BEAT" 2>/dev/null || true)
for sym in entertainmentFrameDuration entertainmentFrameNanoseconds minOnsetPeriod \
           minOnsetLedgerPeriod onsetComparisonTolerance onsetRiseThreshold onsetColorDelta \
           redFlashLuminanceDelta saturatedRedFraction clampedInt \
           dimmingLuminance linearRGB chromaticityLuminanceFactor redDriveFraction \
           relativeLuminance isSaturatedRed luminanceTroughSinceOnset \
           Reservation commit forgetWire \
           slowestPlannedHz minCycleFrames entertainmentMaxLockHz cycleFrames splitFrames \
           WireFrame FrameVerdict OnsetGate OnsetLedger StrobePlan PartyPlan ThunderstormPlan \
           requestedGapFrames flashFrameRange afterglowFrameRange noteAmbient noteStrike gapFrames; do
    echo "$hc_beat_code" \
        | grep -qE "^[[:space:]]*((static|mutating|private|public|internal|final)[[:space:]]+)*(let|var|func|struct|class|enum)[[:space:]]+${sym}([^A-Za-z0-9_]|\$)" \
        || fail "slice2-r1" "BeatMath.FlashSafety.$sym is no longer DECLARED in $HC_BEAT (a comment mentioning it does not count)"
done

# (b) The plans compute a SAFE TOTAL first and split it. Flooring two halves
#     independently is the exact arithmetic that produced sub-1/3 s cycles.
hc_strobe_plan=$(awk '/struct StrobePlan/,/^        }$/' "$HC_BEAT" 2>/dev/null || true)
hc_party_plan=$(awk '/struct PartyPlan/,/^        }$/' "$HC_BEAT" 2>/dev/null || true)
for n in strobe party; do
    eval "body=\$hc_${n}_plan"
    echo "$body" | grep -q 'cycleFrames(' \
        || fail "slice2-r1" "${n}Plan no longer plans a whole safe cycle via cycleFrames("
    echo "$body" | grep -q 'splitFrames(' \
        || fail "slice2-r1" "${n}Plan no longer splits its safe total via splitFrames("
done

# (c) Function-scoped: each ENT loop still routes through the math. Comment-only
#     lines are stripped, because the prose above each fix necessarily quotes the
#     literals the rule bans.
hc_ent_loop() { awk "/private func $1\(/,/^    }\$/" "$HC_ORCH" 2>/dev/null | grep -vE '^[[:space:]]*//' || true; }

for loop in runStrobeEntertainment runPartyEntertainment runThunderstormEntertainment; do
    body=$(hc_ent_loop "$loop")
    [[ -n "$body" ]] || fail "slice2-r1" "$loop not found in $HC_ORCH"
    echo "$body" | grep -q 'onsetLedger: BeatMath.FlashSafety.OnsetLedger' \
        || fail "slice2-r1" "$loop no longer takes the bridge's shared onsetLedger"
    echo "$body" | grep -q 'emitGatedFrame(' \
        || fail "slice2-r1" "$loop no longer streams through the frame gate (emitGatedFrame()"
    echo "$body" | grep -qE 'Task\.sleep\(nanoseconds: [0-9_]+\)' \
        && fail "slice2-r1" "$loop sleeps a hard-coded frame literal"
    echo "$body" | grep -q '0\.02' \
        && fail "slice2-r1" "$loop does frame arithmetic against a 0.02 literal instead of FlashSafety"
    echo "$body" | grep -q 'binding\.beatsPerCycle' \
        && fail "slice2-r1" "$loop uses the RAW binding.beatsPerCycle (R1-TB)"
    echo "$body" | grep -qE '(^|[^A-Za-z0-9_])Int\(p\[' \
        && fail "slice2-r1" "$loop converts a live param-box Double with a bare Int(...) — Int(.nan) and Int(.infinity) TRAP, before any range downstream gets to clamp them; use BeatMath.FlashSafety.clampedInt"
    # The binding identifier is not pinned — the storm's beat wait deliberately
    # re-reads the box into `liveBinding` each frame so a lock toggle can exit
    # the wait — but every liveLock MUST carry the realizable ceiling, and there
    # must be at least one: `0 == 0` is a vacuous pass that a loop with its beat
    # branch deleted (or its lock inlined) would sail straight through.
    hc_locks=$(echo "$body" | grep -c 'BeatMath\.liveLock(' || true)
    hc_capped=$(echo "$body" | grep -cE 'BeatMath\.liveLock\([A-Za-z_][A-Za-z0-9_]*, maxHz: BeatMath\.FlashSafety\.entertainmentMaxLockHz\)' || true)
    [[ "$hc_locks" -ge 1 ]] \
        || fail "slice2-r1" "$loop no longer calls BeatMath.liveLock( at all — its beat branch cannot be rate-capped if it does not exist"
    [[ "$hc_locks" == "$hc_capped" ]] \
        || fail "slice2-r1" "$loop has a liveLock( without maxHz: entertainmentMaxLockHz ($hc_capped of $hc_locks capped)"
done

hc_ent_loop runStrobeEntertainment | grep -q 'FlashSafety.StrobePlan.make(' \
    || fail "slice2-r1" "runStrobeEntertainment no longer plans with StrobePlan.make("
hc_ent_loop runPartyEntertainment | grep -q 'FlashSafety.PartyPlan.make(' \
    || fail "slice2-r1" "runPartyEntertainment no longer plans with PartyPlan.make("

# Thunderstorm has no fixed cycle to floor — its safety is the carried budget.
hc_storm_body=$(hc_ent_loop runThunderstormEntertainment)
for call in 'ThunderstormPlan.Budget()' 'noteAmbient(' 'noteStrike(' 'gapFrames(frequency:'; do
    echo "$hc_storm_body" | grep -qF "$call" \
        || fail "slice2-r1" "runThunderstormEntertainment lost its onset budget ($call missing)"
done

# (d) The ledger is per BRIDGE and is never dropped. Removing it mid-session
#     re-bases the wall clock, which is precisely how two loops on one bridge
#     realized two onsets less than 1/3 s apart.
grep -q 'studioFlashOnsetLedgersByBridge' "$HC_ORCH" \
    || fail "slice2-r1" "the per-bridge flash onset ledger is gone"
hc_ledger_drop=$(grep -nE 'studioFlashOnsetLedgersByBridge\.(removeValue|removeAll)|studioFlashOnsetLedgersByBridge\[[^]]*\][[:space:]]*=[[:space:]]*nil' "$HC_ORCH" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -n "$hc_ledger_drop" ]]; then
    fail "slice2-r1" $'a flash onset ledger is being removed:\n'"$hc_ledger_drop"
fi

# (e) The frame helper is the ONE place a flash-class ENT loop may send, and it
#     asks the ledger about the FRAME. `emitGatedFrame` and `emitOnsetFrame` are
#     the pieces of this invariant no unit test can execute (they need a live
#     HueEntertainmentClient), so their shape is pinned here instead.
#
#     The rule they encode: what goes on the wire is what the ledger RECORDED,
#     never what the caller asked for. Every hole the second pass found was a
#     frame the loop emitted while the ledger was looking at something else — the
#     hold frame a caller assembled from `lastBri ?? minBri` (B1), the storm's
#     ambient frame after an afterglow (H1), the strobe's OFF edge when it is the
#     rising one (H2).
hc_emit_body=$(awk '/private func emitGatedFrame\(/,/^    }$/' "$HC_ORCH" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
[[ -n "$hc_emit_body" ]] || fail "slice2-r1" "emitGatedFrame is gone from $HC_ORCH"
echo "$hc_emit_body" | grep -q 'ledger.admit(' \
    || fail "slice2-r1" "emitGatedFrame no longer asks the shared ledger about the FRAME through admit("
echo "$hc_emit_body" | grep -q 'let onWire = reservation.frame' \
    || fail "slice2-r1" "emitGatedFrame no longer takes its wire frame from the reservation the ledger returned — a hold that re-derives its own level is defect B1"

# Third pass, blocker B-1: the ledger may not run ahead of the wire. `admit`
# only RESERVES; the send answers whether the transport took the frame; `commit`
# is what makes the reservation true or rolls it back. The ORDER is the whole
# invariant — a commit before the send is the old stamp-then-hope, and a missing
# commit leaves the ledger holding a frame nobody saw. Both are checked
# positionally, because a body containing all three tokens in the wrong order
# reads exactly like a body containing them in the right one.
echo "$hc_emit_body" | grep -q 'ledger.commit(' \
    || fail "slice2-r1" "emitGatedFrame never commits its reservation — the ledger would keep a record of a frame the transport may have dropped (B-1)"
hc_admit_at=$(echo "$hc_emit_body" | grep -n 'ledger.admit(' | head -1 | cut -d: -f1)
hc_send_at=$(echo "$hc_emit_body" | grep -n 'sendUniform(' | head -1 | cut -d: -f1)
hc_commit_at=$(echo "$hc_emit_body" | grep -n 'ledger.commit(' | head -1 | cut -d: -f1)
[[ "$hc_admit_at" -lt "$hc_send_at" ]] \
    || fail "slice2-r1" "emitGatedFrame sends before it reserves (admit at $hc_admit_at, sendUniform at $hc_send_at)"
[[ "$hc_send_at" -lt "$hc_commit_at" ]] \
    || fail "slice2-r1" "emitGatedFrame commits at line $hc_commit_at, BEFORE its sendUniform( at line $hc_send_at — the commit must record what the transport actually did, and it is also what stamps the onset at DELIVERY time (H-3)"
echo "$hc_emit_body" | grep -qE 'let delivered = await [A-Za-z]+\.sendUniform\(' \
    || fail "slice2-r1" "emitGatedFrame discards sendUniform's answer — a frame the transport refused mid-reconnect changed no light, and a ledger that cannot tell runs ahead of the wire (B-1)"
echo "$hc_emit_body" | grep -q 'delivered: delivered' \
    || fail "slice2-r1" "emitGatedFrame does not pass the transport's answer to commit(delivered:)"

# Fifth review round. Three shapes the reserve/commit pair cannot be edited out of.
#
# (i) NOTHING may return between the send and the commit. The comment above the
#     commit says so; a `guard Task.isCancelled else { return }` slipped in there
#     would still read as careful code and would leave the ledger holding a frame
#     the wire never saw — the dropped-send defect by another route (M-2).
hc_send_line=$(echo "$hc_emit_body" | grep -n 'sendUniform(' | head -1 | cut -d: -f1)
hc_commit_line=$(echo "$hc_emit_body" | grep -n 'ledger.commit(' | head -1 | cut -d: -f1)
hc_between=$(echo "$hc_emit_body" | sed -n "$((hc_send_line + 1)),$((hc_commit_line - 1))p" \
    | grep -nE '(^|[^A-Za-z0-9_])return([^A-Za-z0-9_]|$)' || true)
if [[ -n "$hc_between" ]]; then
    fail "slice2-r1" $'emitGatedFrame can return between its sendUniform( and its ledger.commit(:\n'"$hc_between"
fi

# (ii) The commit is stamped with a clock sample taken AT the commit, not with a
#      value hoisted before the send. Hoisting it silently restores H-3: the
#      onset's reference point goes back to decision time, and the realized
#      spacing can be shorter than the period the gate enforces.
echo "$hc_emit_body" | grep -qE 'ledger\.commit\(reservation, delivered: delivered, at: CACurrentMediaTime\(\)\)' \
    || fail "slice2-r1" "emitGatedFrame does not commit at: CACurrentMediaTime() — a hoisted sample stamps the onset at DECISION time and concedes the actor hop back (H-3)"

# `sendUniform` has to HAVE an answer to pass.
grep -qE '^[[:space:]]*func sendUniform\(.*\) -> Bool' "$HC_ENT" \
    || fail "slice2-r1" "HueEntertainmentClient.sendUniform no longer returns Bool — nothing downstream can tell a delivered frame from one the reconnect dropped (B-1)"
grep -qE '^[[:space:]]*func send\(channels:.*\) -> Bool' "$HC_ENT" \
    || fail "slice2-r1" "HueEntertainmentClient.send(channels:) no longer returns Bool"

echo "$hc_emit_body" | grep -q 'minOnsetLedgerPeriod' \
    || fail "slice2-r1" "emitGatedFrame no longer enforces the 17-frame minOnsetLedgerPeriod (minOnsetPeriod concedes 6.67 ms the cross-run path cannot afford)"
echo "$hc_emit_body" | grep -q 'BeatMath.FlashSafety.entertainmentFrameNanoseconds' \
    || fail "slice2-r1" "emitGatedFrame no longer sleeps the shared 20 ms frame quantum"
echo "$hc_emit_body" | grep -qE 'Task\.sleep\(nanoseconds: [0-9_]+\)' \
    && fail "slice2-r1" "emitGatedFrame sleeps a hard-coded frame literal"
hc_emit_sends=$(echo "$hc_emit_body" | grep -c 'sendUniform(' || true)
[[ "$hc_emit_sends" == "1" ]] \
    || fail "slice2-r1" "emitGatedFrame makes $hc_emit_sends sendUniform( calls — it must make exactly one, so every frame is gated exactly once"
echo "$hc_emit_body" | grep -q 'x: onWire.x, y: onWire.y, brightness: onWire.brightness' \
    || fail "slice2-r1" "emitGatedFrame sends something other than the frame the ledger recorded (onWire) — sending the REQUESTED frame after a refusal is the whole defect"

# `emitOnsetFrame` is the successor to `streamUntilOnsetAdmitted` and inherits its
# one hard rule: a refusal is a DELAY, never a skip. A numeric bail-out — "give up
# after N frames and flash anyway" — would convert every refusal into exactly the
# skip R1 rule 4 forbids. It is banned in BOTH spellings (`held > N` and
# `N < held`), and in fact no numeric comparison belongs in that body at all.
hc_onset_body=$(awk '/private func emitOnsetFrame\(/,/^    }$/' "$HC_ORCH" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
[[ -n "$hc_onset_body" ]] || fail "slice2-r1" "emitOnsetFrame is gone from $HC_ORCH"
echo "$hc_onset_body" | grep -q 'while !Task.isCancelled' \
    || fail "slice2-r1" "emitOnsetFrame no longer loops until the frame lands — only cancellation may end the wait"
echo "$hc_onset_body" | grep -q 'emitGatedFrame(' \
    || fail "slice2-r1" "emitOnsetFrame no longer streams its wait through the frame gate"
echo "$hc_onset_body" | grep -q 'landedOnWire' \
    || fail "slice2-r1" "emitOnsetFrame no longer returns on the REQUESTED frame reaching the WIRE (landedOnWire) — 'wasAdmitted' alone means the ledger agreed, which says nothing about a transport that dropped the frame mid-reconnect (B-1)"
echo "$hc_onset_body" | grep -qE '[<>]=?[[:space:]]*[0-9]|[0-9][[:space:]]*[<>]=?' \
    && fail "slice2-r1" "emitOnsetFrame compares against a numeric bound — a refusal must DELAY the flash, never skip it (both spellings of the bail-out are banned)"

# (f) Every loop is started with the PER-BRIDGE ledger, resolved before it. A
#     fresh `OnsetLedger()` at the call site type-checks, reads as correct, and
#     silently restores the cross-run defect the ledger exists to prevent: each
#     card switch would start with an empty ledger and flash on frame one.
hc_ledger_decl=$(grep -n 'let flashLedger = flashOnsetLedger(forBridge:' "$HC_ORCH" 2>/dev/null | head -1 | cut -d: -f1)
[[ -n "$hc_ledger_decl" ]] \
    || fail "slice2-r1" "startStreamingEngine no longer resolves the bridge's ledger through flashOnsetLedger(forBridge:"
for loop in runStrobeEntertainment runPartyEntertainment runThunderstormEntertainment; do
    hc_call_line=$(grep -n "self\.${loop}(entClient:" "$HC_ORCH" 2>/dev/null | head -1 | cut -d: -f1)
    [[ -n "$hc_call_line" ]] || fail "slice2-r1" "$loop is never started from startStreamingEngine"
    [[ "$hc_call_line" -gt "$hc_ledger_decl" ]] \
        || fail "slice2-r1" "$loop is started at line $hc_call_line, before the bridge ledger is resolved at line $hc_ledger_decl"
    hc_ledger_arg=$(sed -n "${hc_call_line},$((hc_call_line + 3))p" "$HC_ORCH" \
        | grep -oE 'onsetLedger: [A-Za-z0-9_.]+' | head -1)
    [[ "$hc_ledger_arg" == "onsetLedger: flashLedger" ]] \
        || fail "slice2-r1" "$loop's call site passes '${hc_ledger_arg:-nothing}' — it must pass the shared per-bridge 'onsetLedger: flashLedger', never a fresh ledger"
done

# (g) The storm's Budget is declared OUTSIDE its render loop. Constructed inside,
#     it would start saturated on every iteration and grant every strike the
#     credit it was invented to withhold.
hc_storm_start=$(grep -n 'private func runThunderstormEntertainment(' "$HC_ORCH" 2>/dev/null | head -1 | cut -d: -f1)
[[ -n "$hc_storm_start" ]] || fail "slice2-r1" "runThunderstormEntertainment is gone from $HC_ORCH"
hc_budget_line=$(awk -v s="$hc_storm_start" 'NR > s && /FlashSafety.ThunderstormPlan.Budget\(\)/ { print NR; exit }' "$HC_ORCH")
hc_storm_while=$(awk -v s="$hc_storm_start" 'NR > s && /while !Task\.isCancelled \{/ { print NR; exit }' "$HC_ORCH")
[[ -n "$hc_budget_line" && -n "$hc_storm_while" && "$hc_budget_line" -lt "$hc_storm_while" ]] \
    || fail "slice2-r1" "runThunderstormEntertainment's Budget() (line ${hc_budget_line:-none}) is not declared before its render loop (line ${hc_storm_while:-none}) — a budget rebuilt each iteration banks fresh credit for every strike"

# (h) The gate measures the WIRE, and NOTHING bypasses it.
#
#     The first pass gated the transitions each loop COMPUTED — a duty edge, a
#     cycle-index change, an ambient raise — and pinned that here by grepping for
#     a `needsGate` expression. That check was operator-blind: it could see that a
#     comparison existed, not that the comparison covered every frame the loop
#     emitted. It could not, and the second pass found four frames that escaped
#     (B1, H1, H2, M4) plus a per-frame epsilon that a slow ramp walked straight
#     past (M3). The rule is now structural instead of textual: a flash-class ENT
#     loop contains ZERO direct sends, so there is no frame left for it to emit
#     behind the ledger's back.
for loop in runStrobeEntertainment runPartyEntertainment runThunderstormEntertainment; do
    body=$(hc_ent_loop "$loop")
    # BOTH transport entry points. Counting only `sendUniform(` left the
    # per-channel `send(channels:)` overload as an ungated back door: a loop
    # could stream every frame through it with this guard green and the
    # ledger measuring nothing. `$body` is already comment-stripped by
    # hc_ent_loop, so a prose mention of either spelling is not a call.
    hc_direct=$(echo "$body" | grep -cE 'sendUniform\(|\.send\(channels:' || true)
    [[ "$hc_direct" == "0" ]] \
        || fail "slice2-r1" "$loop makes $hc_direct direct transport call(s) (sendUniform( / .send(channels:) — every frame must go through emitGatedFrame(, or the ledger is measuring something other than the wire"
    hc_gated=$(echo "$body" | grep -c 'emitGatedFrame(' || true)
    [[ "$hc_gated" -ge 1 ]] \
        || fail "slice2-r1" "$loop makes no emitGatedFrame( call — a loop that streams nothing through the gate is not gated at all"
done

# (i) (Slice 3) THE COMPOSITION LOOP IS FLASH-CLASS TOO.
#
#     `runCompositionEntertainment` was omitted from the list above because it
#     streams a frame PER CHANNEL and so cannot call `emitGatedFrame`, which is
#     uniform. The omission was not a judgement that compositions cannot flash:
#     `EnvelopeConfig.value(at:)` renders `.pulse` as a SQUARE wave at `bpm/60`
#     Hz with `bpm` authored to 240 — a full-depth 4 Hz on/off across every
#     light — and `.flicker` carries an unconditional ~3.68 Hz component at any
#     tempo. The loop sent straight to the transport at 25 fps, with no ledger
#     and the delivery answer discarded, so both realized above the ceiling.
#
#     Same structural rule, its own gate: zero direct sends, every frame through
#     `emitGatedCompositionFrame`.
hc_comp_body=$(hc_ent_loop runCompositionEntertainment)
[[ -n "$hc_comp_body" ]] \
    || fail "slice3-flash" "runCompositionEntertainment not found in $HC_ORCH — the composition flash rule is unenforceable"
hc_comp_direct=$(echo "$hc_comp_body" | grep -cE 'sendUniform\(|\.send\(channels:' || true)
[[ "$hc_comp_direct" == "0" ]] \
    || fail "slice3-flash" "runCompositionEntertainment makes $hc_comp_direct direct transport call(s) — a composition frame that skips emitGatedCompositionFrame( is a frame the ledger never measured, and .pulse @ 240 bpm is 4 Hz"
echo "$hc_comp_body" | grep -q 'emitGatedCompositionFrame(' \
    || fail "slice3-flash" "runCompositionEntertainment no longer streams through emitGatedCompositionFrame("
# The ledger must be THE BRIDGE'S, shared with the uniform loops. A composition
# holding its own would get a fresh 0.34 s budget beside a Strobe on the same
# wire, and each could admit an onset one frame after the other's.
echo "$hc_comp_body" | grep -q 'flashOnsetLedger(forBridge:' \
    || fail "slice3-flash" "runCompositionEntertainment no longer resolves the per-bridge shared ledger — a private ledger measures one loop, not the wire"
# Only a DELIVERED frame becomes the held frame. Holding a dropped one would
# repeat something no light ever displayed.
echo "$hc_comp_body" | grep -qE 'if[[:space:]]+gated\.outcome\.delivered[[:space:]]*\{[[:space:]]*lastEmitted' \
    || fail "slice3-flash" "runCompositionEntertainment updates its held frame without checking delivery — a frame the transport dropped is not what the bridge is showing"

# The composition gate's own body: reserve → send → commit, in that order, with
# nothing between the send and the commit, and the reservation taken on the
# FIELD reduction rather than on one arbitrary channel.
hc_comp_emit=$(awk '/private func emitGatedCompositionFrame\(/,/^    }$/' "$HC_ORCH" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
[[ -n "$hc_comp_emit" ]] \
    || fail "slice3-flash" "emitGatedCompositionFrame is gone from $HC_ORCH"
echo "$hc_comp_emit" | grep -q 'BeatMath.FlashSafety.fieldFrame(' \
    || fail "slice3-flash" "emitGatedCompositionFrame no longer reserves on FlashSafety.fieldFrame( — measuring one channel is not measuring the field a viewer receives"
echo "$hc_comp_emit" | grep -q 'BeatMath.FlashSafety.minOnsetLedgerPeriod' \
    || fail "slice3-flash" "emitGatedCompositionFrame no longer enforces minOnsetLedgerPeriod (0.34 s, the invariant's own unit)"
hc_ce_admit=$(echo "$hc_comp_emit" | grep -n 'ledger.admit(' | head -1 | cut -d: -f1)
hc_ce_send=$(echo "$hc_comp_emit" | grep -n '\.send(channels:' | head -1 | cut -d: -f1)
hc_ce_commit=$(echo "$hc_comp_emit" | grep -n 'ledger.commit(' | head -1 | cut -d: -f1)
[[ -n "$hc_ce_admit" && -n "$hc_ce_send" && -n "$hc_ce_commit" ]] \
    || fail "slice3-flash" "emitGatedCompositionFrame is missing one of admit/send/commit — all three, in that order, are the mechanism"
[[ "$hc_ce_admit" -lt "$hc_ce_send" && "$hc_ce_send" -lt "$hc_ce_commit" ]] \
    || fail "slice3-flash" "emitGatedCompositionFrame's admit/send/commit are out of order (admit=$hc_ce_admit send=$hc_ce_send commit=$hc_ce_commit) — committing before the send stamps an onset the wire may never have shown"
# No exit between the send and the commit: bailing out there leaves the ledger
# holding a frame the wire never saw (M-2), the same defect as a dropped send by
# another route.
hc_ce_between=$(echo "$hc_comp_emit" | sed -n "$((hc_ce_send + 1)),$((hc_ce_commit - 1))p" \
    | grep -cE '(^|[^A-Za-z0-9_])(return|throw|break|continue)([^A-Za-z0-9_]|$)' || true)
[[ "$hc_ce_between" == "0" ]] \
    || fail "slice3-flash" "emitGatedCompositionFrame can exit between its send and its commit — the ledger would keep an onset the wire never showed"
# A refusal repeats the frame ALREADY on the wire. Reconstructing one is how the
# first pass shipped a hold frame that was itself a rise (blocker B1).
echo "$hc_comp_emit" | grep -q 'lastEmitted' \
    || fail "slice3-flash" "emitGatedCompositionFrame no longer holds the last emitted per-channel frame — a refusal must repeat what the bridge is showing, not a reconstruction"

# The field reduction itself. These pin the two choices that decide whether a
# real flash is measured: the MEAN of the channels' luminances (not the max, and
# not the cube of the mean dimming, which understates every mixed frame), and a
# LUMINANCE-WEIGHTED chromaticity (so a chase's dark tail cannot dilute the red
# rule). Scoped to the function body so the prose above it cannot satisfy them.
hc_field=$(awk '/static func fieldFrame\(/,/^        \}$/' "$HC_BEAT" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
[[ -n "$hc_field" ]] \
    || fail "slice3-flash" "BeatMath.FlashSafety.fieldFrame is gone from $HC_BEAT"
echo "$hc_field" | grep -q 'relativeLuminance } / count' \
    || fail "slice3-flash" "fieldFrame no longer averages the channels' relativeLuminance — a max reduction gates a single twinkling lamp as a room-wide flash, and averaging DIMMING instead understates every mixed frame"
echo "$hc_field" | grep -q 'relativeLuminance } / totalWeight' \
    || fail "slice3-flash" "fieldFrame's chromaticity is no longer luminance-weighted — an unweighted mean lets a dark tail drag a saturated-red strike off red until the red rule stops firing"
echo "$hc_field" | grep -q 'inverseDimmingLuminance(' \
    || fail "slice3-flash" "fieldFrame no longer inverts the dimming curve — without it the returned frame's own relativeLuminance is not the field luminance the gate was asked to measure"
# (The suite that proves all of the above is pinned into the target's Sources
# phase by the existing FlashSafetyTests membership check further down.)

# The gate tracks the wire state it measures rises against, and RECORDS what it
# emitted. Scoped to the struct body: a file-wide grep would be satisfied by the
# prose above each fix, which necessarily names every symbol it explains.
hc_gate_body=$(awk '/^        struct OnsetGate \{/,/^        \}$/' "$HC_BEAT" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
[[ -n "$hc_gate_body" ]] || fail "slice2-r1" "BeatMath.FlashSafety.OnsetGate is gone from $HC_BEAT"
for decl in 'var lastEmitted' 'var luminanceTroughSinceOnset' \
            'func admit(frame' 'func isOnsetCandidate(' 'func commit(' 'func forgetWire('; do
    echo "$hc_gate_body" | grep -qF "$decl" \
        || fail "slice2-r1" "OnsetGate no longer declares '$decl' — without the wire state, the luminance trough and the reserve/commit pair the gate is back to measuring what the loop computed"
done
echo "$hc_gate_body" | grep -q 'lastEmitted = frame' \
    || fail "slice2-r1" "OnsetGate.admit no longer RECORDS the frame it emitted — a gate that does not remember the wire cannot hold it"
echo "$hc_gate_body" | grep -q 'min(luminanceTroughSinceOnset,' \
    || fail "slice2-r1" "OnsetGate no longer lowers luminanceTroughSinceOnset toward the darkest EMITTED frame — a rise measured against the previous frame is a slew limit, and a 0.019/frame ramp walks straight past it (defect M3)"
echo "$hc_gate_body" | grep -q 'FlashSafety.onsetRiseThreshold' \
    || fail "slice2-r1" "OnsetGate's candidacy test no longer uses the shared onsetRiseThreshold"
echo "$hc_gate_body" | grep -qE 'return[[:space:]]+\.hold\(|reservation\(\.hold\(' \
    || fail "slice2-r1" "OnsetGate.admit never yields .hold — a refusal must yield the frame already on the wire (or black, when there isn't one), not a level the caller invents"

# Third pass, H-1/H-2/M-3: candidacy is measured in RELATIVE LUMINANCE, not in
# Hue dimming. A dimming rule misses a 0.235-of-maximum flash at the top of the
# range (0.901 → 1.000) and reads a 0.60 luminance RISE (blue 0.90 → white 0.85)
# as a decay. The candidacy body is scoped on its own: a file-wide grep would be
# satisfied by the paragraph that explains the fix.
hc_candidacy=$(echo "$hc_gate_body" | awk '/func isOnsetCandidate\(/,/^            \}$/' || true)
[[ -n "$hc_candidacy" ]] || fail "slice2-r1" "OnsetGate.isOnsetCandidate is gone"
echo "$hc_candidacy" | grep -q 'relativeLuminance' \
    || fail "slice2-r1" "OnsetGate.isOnsetCandidate no longer measures relativeLuminance — a threshold applied to Hue dimming is not the WCAG threshold (H-1)"
echo "$hc_candidacy" | grep -q 'luminanceTroughSinceOnset' \
    || fail "slice2-r1" "OnsetGate.isOnsetCandidate no longer measures the rise from the LUMINANCE trough"
echo "$hc_candidacy" | grep -qE '\.brightness' \
    && fail "slice2-r1" "OnsetGate.isOnsetCandidate reads .brightness — candidacy is stated in relative luminance and nothing else (H-1/H-2/M-3)"
echo "$hc_candidacy" | grep -q 'isSaturatedRed' \
    || fail "slice2-r1" "OnsetGate.isOnsetCandidate no longer applies the WCAG red-flash rule — chromaticity's only rule of its own"
echo "$hc_candidacy" | grep -q 'FlashSafety.redFlashLuminanceDelta' \
    || fail "slice2-r1" "OnsetGate.isOnsetCandidate no longer uses the shared redFlashLuminanceDelta"
# The exemption that the luminance model made unnecessary must stay gone: a
# chroma rule that fires on any palette step needs one, and needing one is the
# signal that the rule is measuring the wrong quantity.
echo "$hc_gate_body" | grep -q 'lastAdmittedBrightness' \
    && fail "slice2-r1" "OnsetGate is carrying a lastAdmittedBrightness exemption again — in luminance the storm's afterglow → ambient step is a FALL and needs no carve-out"

# (iii) The gate's model of the wire is restored — not forgotten — when a send is
#       refused, and it tracks when anything last reached the transport. These are
#       declarations, not mentions: a future edit that quietly goes back to
#       forget-on-drop would otherwise pass on the paragraphs that explain why it
#       must not. A refused send changed nothing on the wire (the bridge is still
#       showing the last DELIVERED frame); a wire nothing has reached for a whole
#       period is the thing that is genuinely unknown.
for decl in 'let priorLastEmitted' 'let priorTrough'; do
    echo "$hc_beat_code" | grep -qE "^[[:space:]]*(fileprivate[[:space:]]+)?${decl}([^A-Za-z0-9_]|\$)" \
        || fail "slice2-r1" "Reservation no longer carries '$decl' — without the pre-admit wire state a refused send cannot be rolled back, and forgetting the wire instead re-opens the black-at-the-requested-chromaticity red flash (B1) and the trough re-base (B2)"
done
echo "$hc_gate_body" | grep -qE '^[[:space:]]*private\(set\) var lastDeliveredAt' \
    || fail "slice2-r1" "OnsetGate no longer declares lastDeliveredAt — the silence clock is what tells a one-frame drop from a reconnect, and without it the wire is either never forgotten or forgotten on every dropped frame"
echo "$hc_gate_body" | grep -qE '^[[:space:]]*private\(set\) var lastKnownFrame' \
    || fail "slice2-r1" "OnsetGate no longer declares lastKnownFrame — a cold refusal would hold black at the REQUESTED chromaticity (a WCAG red flash against the frame still on the wire) and the cold path would lose the red-flash rule"
echo "$hc_gate_body" | grep -q 'lastEmitted = reservation.priorLastEmitted' \
    || fail "slice2-r1" "OnsetGate.commit no longer RESTORES the wire state on a refused send — a frame the transport never took changed nothing, and forgetting it is defect B1/B2 (fifth review round)"
echo "$hc_gate_body" | grep -q 'luminanceTroughSinceOnset = reservation.priorTrough' \
    || fail "slice2-r1" "OnsetGate.commit no longer restores the luminance trough on a refused send — the cold path re-bases it upward, and every rise measured after that is short (B2)"
hc_admit_body=$(echo "$hc_gate_body" | awk '/mutating func admit\(frame:/,/^            \}$/' || true)
[[ -n "$hc_admit_body" ]] || fail "slice2-r1" "OnsetGate.admit is gone"
echo "$hc_admit_body" | grep -q 'lastDeliveredAt' \
    || fail "slice2-r1" "OnsetGate.admit no longer consults lastDeliveredAt — a wire that has been silent for a whole period is unknown, and that is the ONLY thing that may forget it (it is also the production trigger forgetWire() never had)"
echo "$hc_admit_body" | grep -q 'forgetWire()' \
    || fail "slice2-r1" "OnsetGate.admit no longer forgets a silent wire"

# The luminance model itself: the two halves and their pairing.
hc_lum_body=$(grep -vE '^[[:space:]]*//' "$HC_BEAT" | awk '/var relativeLuminance/,/^            \}$/' || true)
echo "$hc_lum_body" | grep -q 'chromaticityLuminanceFactor' \
    || fail "slice2-r1" "WireFrame.relativeLuminance no longer scales by the chromaticity factor — dimming alone treats saturated blue and white as the same flash"
echo "$hc_lum_body" | grep -q 'dimmingLuminance' \
    || fail "slice2-r1" "WireFrame.relativeLuminance no longer converts dimming through the CIE L* cube"
echo "$hc_beat_code" | grep -qE '0\.2126|0\.7152|0\.0722' \
    || fail "slice2-r1" "the sRGB luminance coefficients are gone from $HC_BEAT — the chromaticity factor cannot be a luminance without them"

# The ledger decides AND records in one critical section, and exposes the commit
# half under the same lock. Two calls would let the other loop instance alive
# during the un-awaited cancel window interleave a frame between them, and the
# trough would then belong to neither loop.
hc_ledger_body=$(awk '/^        final class OnsetLedger/,/^        \}$/' "$HC_BEAT" 2>/dev/null | grep -vE '^[[:space:]]*//' || true)
echo "$hc_ledger_body" | grep -q 'return gate.admit(frame:' \
    || fail "slice2-r1" "OnsetLedger no longer forwards admit( to its gate under the lock"
echo "$hc_ledger_body" | grep -q 'gate.commit(' \
    || fail "slice2-r1" "OnsetLedger no longer forwards commit( to its gate under the lock — a reservation the loops cannot settle is a ledger running ahead of the wire (B-1)"

echo "$hc_storm_body" | grep -q 'FlashSafety.clampedInt(' \
    || fail "slice2-r1" "runThunderstormEntertainment no longer converts its param-box Ints through the finite-guarded FlashSafety.clampedInt"

# (i) The suite exists and is actually compiled.
[[ -f HueHomeTests/FlashSafetyTests.swift ]] || fail "slice2-r1" "FlashSafetyTests.swift is gone"
grep -q 'FlashSafetyTests.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "slice2-r1" "FlashSafetyTests.swift is not in the test target Sources phase"

# ──────────────────────────────────────────────────────────────
# Guard 15 (Slice 2 R2): ONE availability funnel governs every board control —
# colour included.
#
# Colour used to answer "can this room do this?" for itself, in the view, while
# every other control asked a separate per-view verdict (`showsEntOnlyHint`,
# `param.entOnly`). Two answers to one question is how a knob ends up live on a
# board whose colour swatch says the room cannot render it. `StudioBoardAvailability`
# is now the single resolver, and BOTH renderers must consult it — a rule that
# is only true inside those two function bodies, so the checks are scoped there
# rather than to the file.
# ──────────────────────────────────────────────────────────────

R2_AVAIL="HueHome/Core/StudioBoardAvailability.swift"
R2_BOARD="HueHome/UI/Studio/StudioBoardView.swift"
R2_WIRING="HueHome/UI/Studio/StudioViewModel+CustomizationWiring.swift"

# (a) The resolver exists and is in the app target.
[[ -f "$R2_AVAIL" ]] || fail "slice2-r2" "$R2_AVAIL is missing — the board availability funnel has no home"
grep -q 'StudioBoardAvailability.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "slice2-r2" "StudioBoardAvailability.swift is not in the app target Sources phase"

# (b) Function-scoped: both renderers resolve through the funnel and take their
#     interactivity from it. A file-wide grep would pass vacuously as soon as
#     ONE of the two kept calling it.
[[ -f "$R2_BOARD" ]] || fail "slice2-r2" "$R2_BOARD is missing — the R2 funnel rule is unenforceable"
r2_board_fn() { awk "/private func $1\(/,/^    }\$/" "$R2_BOARD" 2>/dev/null | grep -vE '^[[:space:]]*//' || true; }

for fn in boardControl colorSection; do
    body=$(r2_board_fn "$fn")
    [[ -n "$body" ]] || fail "slice2-r2" "$fn not found in $R2_BOARD"
    echo "$body" | grep -q 'StudioBoardAvailability.resolve(' \
        || fail "slice2-r2" "$fn no longer resolves through StudioBoardAvailability.resolve( — colour and the Live-card controls would answer the same question twice"
    echo "$body" | grep -q 'StudioBoardAvailability.isInteractive(' \
        || fail "slice2-r2" "$fn no longer takes its interactivity from StudioBoardAvailability.isInteractive("
done

# (c) The pre-funnel per-view verdicts stay gone. Comment-only lines are
#     stripped so the history above the fix may keep naming them.
#     The comment filter is ANCHORED (Guard 13(a)'s form). The unanchored
#     `:[[:space:]]*//` matched any line containing "://", so a single trailing
#     `// https://…` comment on a real `showsEntOnlyHint` line hid it from the
#     guard entirely.
r2_legacy=$(grep -nE 'showsEntOnlyHint|param\.entOnly' "$R2_BOARD" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
if [[ -n "$r2_legacy" ]]; then
    fail "slice2-r2" $'a per-view availability verdict is back in '"$R2_BOARD"$' — the funnel is no longer the only answer:\n'"$r2_legacy"
fi

# (d) The colour context reads the SAME snapshot the board resolves against.
#     Scoped to the function: this file is edited elsewhere for unrelated wiring.
r2_color_ctx=$(awk '/func colorCapabilityContext\(/,/^    }$/' "$R2_WIRING" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_color_ctx" ]] || fail "slice2-r2" "colorCapabilityContext is gone from $R2_WIRING — colour would source its coverage somewhere the board never sees"
echo "$r2_color_ctx" | grep -qF 'targetSnapshot(for: effect).color' \
    || fail "slice2-r2" "colorCapabilityContext no longer takes its coverage from targetSnapshot(for: effect).color — colour would drift from the board's snapshot again"

# (e) The suite exists and is actually compiled.
[[ -f HueHomeTests/StudioBoardAvailabilityTests.swift ]] \
    || fail "slice2-r2" "StudioBoardAvailabilityTests.swift is gone"
grep -q 'StudioBoardAvailabilityTests.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "slice2-r2" "StudioBoardAvailabilityTests.swift is not in the test target Sources phase"

# (f) Hidden means DO NOT RENDER (spec §17). Resolving through the funnel is
#     only half the rule: a renderer that stops gating on the funnel's own
#     render predicate falls through to drawing the control dimmed-but-present,
#     which is precisely the state Hidden exists to avoid. Scoped per body —
#     one renderer keeping it would otherwise mask the other losing it.
for fn in boardControl colorSection; do
    body=$(r2_board_fn "$fn")
    [[ -n "$body" ]] || fail "slice2-r2" "$fn not found in $R2_BOARD"
    echo "$body" | grep -qF 'StudioBoardAvailability.rendersControl(' \
        || fail "slice2-r2" "$fn no longer gates on StudioBoardAvailability.rendersControl( — a Hidden control would render present-but-dead instead of not at all"
done

# (g) The funnel is asked in its FAIL-CLOSED form: note/interactivity/opacity
#     are all strategy-qualified with the CARD's own strategy. Drop the
#     argument (or let it default) and a bridge-native card gets judged by
#     app-driven rules — the dead knob comes back live.
for fn in boardControl colorSection; do
    body=$(r2_board_fn "$fn")
    echo "$body" | grep -qF 'strategy: card.strategy' \
        || fail "slice2-r2" "$fn no longer passes strategy: card.strategy into the funnel — the availability verdict would stop being fail-closed for this card's strategy"
done

# (h) Colour's two floors beneath the wrapper's `.disabled`. The hue/saturation
#     pad is a raw drag surface, so the editor must be TOLD it is dead
#     (isInteractive:) and handed a no-op apply (onApply:). Either one alone
#     leaves a gesture path from a dead swatch to the view model.
r2_color_body=$(r2_board_fn colorSection)
echo "$r2_color_body" | grep -qF 'onApply: interactive' \
    || fail "slice2-r2" "colorSection no longer swaps in a no-op onApply when the control is not interactive — a dead colour editor's own gestures could still commit"
#     Scoped to the StageColorEditor CALL. A bare body-wide grep for
#     `isInteractive: interactive` was satisfied by the sibling
#     `colorExpansionBinding(controlID, isInteractive: interactive)` line, so
#     mutating the editor's own argument to `isInteractive: true` passed green.
#     The editor's argument list is the region between its call and the
#     `isExpanded:` argument that follows it.
r2_color_editor=$(echo "$r2_color_body" | awk '/StageColorEditor\(/,/isExpanded:/')
[[ -n "$r2_color_editor" ]] \
    || fail "slice2-r2" "the StageColorEditor( call is gone from colorSection — the funnel's verdict has nothing to reach"
echo "$r2_color_editor" | grep -qF 'isInteractive: interactive' \
    || fail "slice2-r2" "colorSection no longer hands the funnel's verdict to StageColorEditor as isInteractive: — a dead editor would still expand and drag"

# (i) The knob/fader floor. `.disabled()` on the wrapper is the gate; inside
#     StudioContinuousControl BOTH raw paths must refuse independently — the
#     value binding's setter (so a gesture that slipped past the gate cannot
#     even LOOK like it worked) and the editing bracket (so no edit session is
#     opened, and left open, over a target nobody may edit). One guard is a
#     half fix, so the count is checked, not the presence.
r2_cont_body=$(awk '/private var control: some View/,/^    }$/' "$R2_BOARD" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_cont_body" ]] \
    || fail "slice2-r2" "StudioContinuousControl's control body not found in $R2_BOARD — the knob/fader interactivity floor is unenforceable"
r2_cont_guards=$(echo "$r2_cont_body" | grep -cF 'guard isInteractive else { return }' || true)
[[ "$r2_cont_guards" -ge 2 ]] \
    || fail "slice2-r2" "StudioContinuousControl.control has $r2_cont_guards of the 2 required 'guard isInteractive else { return }' floors — the value binding AND the edit-session bracket must each refuse a non-interactive gesture"

# (j) A board that resolves "CHECKING WHAT THESE LIGHTS SUPPORT" against an
#     empty inventory must be able to LEAVE that state. Two halves, each true
#     only inside the body that owns it: the warm path has to fetch lights
#     when only the light cache is cold, and the arriving inventory has to be
#     an observable fact the snapshot depends on (lightsByBridge is
#     @ObservationIgnored, so nothing else wakes the view).
R2_ORCH="HueHome/Core/Network/UnifiedOrchestrator.swift"
[[ -f "$R2_ORCH" ]] || fail "slice2-r2" "$R2_ORCH is missing — the inventory-arrival rule is unenforceable"

r2_warm=$(awk '/func warmEntertainmentCaches\(for room/,/^    }$/' "$R2_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_warm" ]] || fail "slice2-r2" "warmEntertainmentCaches(for room:) not found in $R2_ORCH"
echo "$r2_warm" | grep -qF 'needsConfigs || needsMembership || needsLights' \
    || fail "slice2-r2" "warmEntertainmentCaches no longer includes needsLights in its early-return guard — a bridge whose configs and membership are already cached would return before fetching lights, and Studio's board would sit on an empty inventory forever"

grep -vE '^[[:space:]]*//' "$R2_ORCH" | grep -qF 'var capabilityInventoryGeneration' \
    || fail "slice2-r2" "capabilityInventoryGeneration is gone from $R2_ORCH — the board would have no observable fact to wake it when a fresh light inventory lands"

r2_seed=$(awk '/func seedRawLightCache\(/,/^    }$/' "$R2_ORCH" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_seed" ]] || fail "slice2-r2" "seedRawLightCache not found in $R2_ORCH"
echo "$r2_seed" | grep -qF 'capabilityInventoryGeneration &+= 1' \
    || fail "slice2-r2" "seedRawLightCache no longer bumps capabilityInventoryGeneration — a seeded inventory would land silently and no board would re-resolve"

r2_snapshot=$(awk '/func targetSnapshot\(for effect/,/^    }$/' "$R2_WIRING" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_snapshot" ]] || fail "slice2-r2" "targetSnapshot(for:) not found in $R2_WIRING"
echo "$r2_snapshot" | grep -qF 'capabilityInventoryGeneration' \
    || fail "slice2-r2" "targetSnapshot(for:) no longer reads the orchestrator's capabilityInventoryGeneration — the snapshot would depend on nothing observable and the 'checking what these lights support' note would never clear"

# (k) The funnel's answer is APPLIED, not merely fetched.
#
#     Every check above pins that the funnel is CALLED. None of them pins that
#     anything is done with what it returns: a body could resolve, compute
#     `interactive`/`opacity`/`note` into unused lets, and render a fully live
#     control — every guard green, the defect back. These three are the exact
#     places the answer reaches the screen, and they are checked per body so
#     one renderer keeping them cannot mask the other losing them.
#
#     `.opacity(opacity)` is deliberately the variable, not a literal: the
#     shape that regressed was `.opacity(0.45)`-style constants and whole-VStack
#     dimming that swallowed the note with the control.
R2_BROWSER="HueHome/UI/Studio/StudioLookBrowserView.swift"
[[ -f "$R2_BROWSER" ]] || fail "slice2-r2" "$R2_BROWSER is missing — the details-panel half of the funnel rule is unenforceable"

#     NON-SHADOWING PIN. `.disabled(!interactive)` and `.opacity(opacity)` name
#     LOCAL BINDINGS, and (b)/(g) only pin that the funnel is called SOMEWHERE
#     in the same body. So the whole rule could be bypassed without deleting a
#     single checked line — leave the `StudioBoardAvailability.isInteractive(…)`
#     call standing under a different name and write `let interactive = true`
#     beside it, and every guard above stays green while a control the funnel
#     refused renders live at full strength. The bypass is cheap to close: the
#     binding the view actually reads must take its value FROM the funnel.
#
#     Checked as a window (the binding line plus the two after it) rather than
#     as one line, because the real call is split across lines in all three
#     bodies and reads through a `live == nil ? …` ternary in the browser's.
r2_binding_pin() {
    local body="$1" where="$2" name="$3" callee="$4"
    local hits n window
    # `let <name>` with an optional type annotation, then `=`. Anchored on the
    # `let` so `isInteractive: interactive` argument lines are not bindings.
    hits=$(echo "$body" | grep -nE "let[[:space:]]+${name}([[:space:]]*:[^=]*)?[[:space:]]*=" || true)
    if [[ -z "$hits" ]]; then
        fail "slice2-r2" "$where binds no \`let $name\` — the funnel's verdict has no name for .disabled/.opacity to read"
        return
    fi
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        n=${hit%%:*}
        # A LITERAL RHS IS THE BYPASS ITSELF. The window below is the binding
        # line plus the two after it, so a decoy written immediately BEFORE
        # the real (differently-named) funnel call sits in a window that
        # CONTAINS the callee and passes — `let interactive = true` and
        # `let opacity: Double = 1` are exactly that shape. A binding whose
        # right-hand side is a bare literal can never be the funnel's answer,
        # whatever happens to be on the next two lines.
        rhs=${hit#*=}
        if [[ "$rhs" =~ ^[[:space:]]*(true|false|-?[0-9]+(\.[0-9]+)?)[[:space:]]*$ ]]; then
            fail "slice2-r2" $''"$where"$' binds `'"$name"$'` to a bare literal — a shadowing constant leaves every other guard green while the funnel\'s answer is thrown away:\n'"$hit"
            continue
        fi
        window=$(echo "$body" | sed -n "${n},$((n + 2))p")
        echo "$window" | grep -qF "$callee" \
            || fail "slice2-r2" $''"$where"$' binds `'"$name"$'` to something other than '"$callee"$' — a shadowing constant (`let interactive = true`, `let opacity: Double = 1`) leaves every other guard green while the funnel\'s answer is thrown away:\n'"$hit"
    done <<< "$hits"
}

r2_applied_check() {
    local body="$1" where="$2"
    echo "$body" | grep -qF '.disabled(!interactive)' \
        || fail "slice2-r2" "$where does not disable on the funnel's verdict (.disabled(!interactive)) — a control the funnel refused would still take gestures"
    echo "$body" | grep -qF '.opacity(opacity)' \
        || fail "slice2-r2" "$where does not apply the funnel's opacity (.opacity(opacity)) — an unproven or staged control would look exactly like a fully live one"
    echo "$body" | grep -qF 'if let note' \
        || fail "slice2-r2" "$where does not render the funnel's note (if let note) — the control would go quiet about why it cannot do what it looks like it does"
    r2_binding_pin "$body" "$where" interactive 'StudioBoardAvailability.isInteractive('
    r2_binding_pin "$body" "$where" opacity 'StudioBoardAvailability.opacity('
}

for fn in boardControl colorSection; do
    r2_applied_check "$(r2_board_fn "$fn")" "$R2_BOARD:$fn"
done

r2_setup_body=$(awk '/private func setupSliderRow\(/,/^    }$/' "$R2_BROWSER" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_setup_body" ]] \
    || fail "slice2-r2" "setupSliderRow not found in $R2_BROWSER — the details-panel hero slider is where the fixed defects were re-committed once already"
echo "$r2_setup_body" | grep -qF 'StudioBoardAvailability.resolve(' \
    || fail "slice2-r2" "setupSliderRow no longer resolves through StudioBoardAvailability.resolve( — the panel's live sliders would answer availability for themselves again"
echo "$r2_setup_body" | grep -qF 'StudioBoardAvailability.rendersControl(' \
    || fail "slice2-r2" "setupSliderRow no longer gates on rendersControl( — a Hidden control would render present-but-dead"
echo "$r2_setup_body" | grep -qF 'strategy: card.strategy' \
    || fail "slice2-r2" "setupSliderRow no longer passes strategy: card.strategy — it would be reading the PRE-funnel overloads, which know nothing about isHardwareUnverified"
echo "$r2_setup_body" | grep -qF 'guard interactive else { return }' \
    || fail "slice2-r2" "setupSliderRow's StageSlider setter has no interactivity floor — StageSlider's track is a raw drag surface, so the wrapper's .disabled cannot be the only gate"
r2_applied_check "$r2_setup_body" "$R2_BROWSER:setupSliderRow"

# (l) Slice 3 (S3-4): the COMPOSER resolves through the same funnel.
#
#     The Composer answered "may the user touch this?" with one boolean,
#     `roomHasColorLights`, defaulting to TRUE, written once per apply into a
#     single view-model slot shared by every running composition. Every other
#     Composer control had no answer at all. `ComposerControlAvailability` is
#     the adapter: catalog control ids, the resolver's own requirements,
#     `targetSnapshot(for:)`, the board's own copy. It ALWAYS returns a
#     resolution, so the Composer calls the non-strategy overloads
#     (`isInteractive(_:)`, `opacity(_:)`, `note(for:isColor:)`) through
#     nil-tolerant wrappers that FAIL CLOSED — that is not a bypass of (g),
#     which exists because the board's `resolve` can return nil.
R2_COMPOSER_AVAIL="HueHome/Core/ComposerControlAvailability.swift"
R2_COMPOSER_PANEL="HueHome/UI/Composer/CompositionEditorPanel.swift"
R2_COMPOSER_SUPPORT="HueHome/UI/Composer/ComposerLayerSheet.swift"
R2_COMPOSER_TESTS="HueHomeTests/ComposerControlAvailabilityTests.swift"
[[ -f "$R2_COMPOSER_AVAIL" ]] || fail "slice2-r2" "$R2_COMPOSER_AVAIL is missing — the Composer has no adapter into the availability funnel"
grep -q 'ComposerControlAvailability.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "slice2-r2" "ComposerControlAvailability.swift exists but is not in the app target"
[[ -f "$R2_COMPOSER_TESTS" ]] || fail "slice2-r2" "$R2_COMPOSER_TESTS is missing — the Composer adapter is unproven"
grep -q 'ComposerControlAvailabilityTests.swift in Sources' HueHome.xcodeproj/project.pbxproj \
    || fail "slice2-r2" "ComposerControlAvailabilityTests.swift exists but is not in the test target — it never runs"

#     The two-state boolean may not return, anywhere.
r2_bool=$(grep -rnE 'roomHasColorLights' HueHome --include='*.swift' 2>/dev/null \
    | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' || true)
[[ -z "$r2_bool" ]] || fail "slice2-r2" $'roomHasColorLights is back — a boolean that defaults to yes is the Composer\'s original capability lie:\n'"$r2_bool"

#     The adapter's requirement table is the resolver's vocabulary — colour
#     controls need `.color`, Warmth needs `.colorTemperature` (which is what
#     makes a schemaless CT fixture read CHECKING instead of a fake 153…500).
r2_avail_src=$(grep -vE '^[[:space:]]*//' "$R2_COMPOSER_AVAIL")
echo "$r2_avail_src" | grep -qF 'if colorControlIDs.contains(controlID) { return .color }' \
    || fail "slice2-r2" "ComposerControlAvailability no longer maps its colour controls to .color"
echo "$r2_avail_src" | grep -qF 'if colorTemperatureControlIDs.contains(controlID) { return .colorTemperature }' \
    || fail "slice2-r2" "ComposerControlAvailability no longer maps Warmth to .colorTemperature"
echo "$r2_avail_src" | grep -qF 'CustomizationResolver.resolve(' \
    || fail "slice2-r2" "ComposerControlAvailability no longer resolves through CustomizationResolver — a parallel availability system"
echo "$r2_avail_src" | grep -qF 'guard let resolution else { return false }' \
    || fail "slice2-r2" "ComposerControlAvailability.isInteractive no longer fails closed on a nil resolution"
echo "$r2_avail_src" | grep -qF 'guard let resolution else { return StudioBoardAvailability.checkingCopy }' \
    || fail "slice2-r2" "ComposerControlAvailability.note no longer reads CHECKING on a nil resolution"
echo "$r2_avail_src" | grep -qF 'guard let range = snapshot?.mirekRange else { return nil }' \
    || fail "slice2-r2" "ComposerControlAvailability.warmthRange no longer comes from the snapshot's mirek range"

#     Every Composer control is gated: the panel and the supporting tier
#     resolve through the context, and the gate APPLIES the verdict the
#     15(k) way — bound to the adapter's non-nil-tolerant wrappers, never to a
#     literal.
for f in "$R2_COMPOSER_PANEL" "$R2_COMPOSER_SUPPORT"; do
    grep -vE '^[[:space:]]*//' "$f" | grep -qF 'availability.resolve("' \
        || fail "slice2-r2" "$f no longer resolves its controls through ComposerAvailabilityContext"
    r2_unresolved=$(grep -nE 'unresolvedIsInteractive|StudioBoardAvailability\.isInteractive\(resolution:' "$f" 2>/dev/null \
        | grep -vE '^[0-9]+:[[:space:]]*//' || true)
    [[ -z "$r2_unresolved" ]] || fail "slice2-r2" $''"$f"$' reaches for the strategy-qualified overloads — for compositions those fail OPEN:\n'"$r2_unresolved"
done
r2_gate=$(awk '/^struct ComposerControlGate</,/^}$/' "$R2_COMPOSER_SUPPORT" 2>/dev/null \
    | grep -vE '^[[:space:]]*//' || true)
[[ -n "$r2_gate" ]] || fail "slice2-r2" "ComposerControlGate not found in $R2_COMPOSER_SUPPORT"
#     The same three "applied" checks as (k), with the COMPOSER adapter as the
#     callee the bindings must read from (`r2_applied_check` pins the board's
#     `StudioBoardAvailability.` callee, which for the Composer would be the
#     fail-open path).
echo "$r2_gate" | grep -qF '.disabled(!interactive)' \
    || fail "slice2-r2" "ComposerControlGate does not disable on the funnel's verdict (.disabled(!interactive))"
echo "$r2_gate" | grep -qF '.opacity(opacity)' \
    || fail "slice2-r2" "ComposerControlGate does not apply the funnel's opacity (.opacity(opacity))"
echo "$r2_gate" | grep -qF 'if let note' \
    || fail "slice2-r2" "ComposerControlGate does not render the funnel's note (if let note)"
r2_binding_pin "$r2_gate" "ComposerControlGate" interactive 'ComposerControlAvailability.isInteractive('
r2_binding_pin "$r2_gate" "ComposerControlGate" opacity 'ComposerControlAvailability.opacity('
echo "$r2_gate" | grep -qF 'ComposerControlAvailability.rendersControl(resolution)' \
    || fail "slice2-r2" "ComposerControlGate no longer honours .hidden through rendersControl"
#     Gestures `.disabled` does not close (the pad's drag, a chip's tap) carry
#     the verdict at the setter.
grep -vE '^[[:space:]]*//' "$R2_COMPOSER_PANEL" | grep -qF 'guard interactive else { return }' \
    || fail "slice2-r2" "$R2_COMPOSER_PANEL has no setter-level `guard interactive` — the pad's drag would write through a refused verdict"
grep -vE '^[[:space:]]*//' "$R2_COMPOSER_SUPPORT" | grep -qF 'func composerGuarded<Value>(_ interactive: Bool, _ binding: Binding<Value>) -> Binding<Value>' \
    || fail "slice2-r2" "composerGuarded is gone from $R2_COMPOSER_SUPPORT — Composer bindings have no setter-level floor"
#     Warmth authors the snapshot's range, never a literal one on a live control.
r2_warmth=$(grep -nE 'range: 153\.\.\.500' "$R2_COMPOSER_PANEL" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*//' || true)
[[ -z "$r2_warmth" ]] || fail "slice2-r2" $'the Composer Warmth control authors a literal 153…500 again (checklist row 58):\n'"$r2_warmth"
grep -vE '^[[:space:]]*//' "$R2_COMPOSER_PANEL" | grep -qF 'range: availability.warmthRange ?? ComposerControlAvailability.fallbackWarmthRange' \
    || fail "slice2-r2" "the Composer Warmth control no longer reads its range from the snapshot"


# ──────────────────────────────────────────────────────────────

if [[ $FAILURES -gt 0 ]]; then
    echo "hardening_guards: $FAILURES guard(s) failed." >&2
    exit 1
fi

echo "hardening_guards: all guards passed."
