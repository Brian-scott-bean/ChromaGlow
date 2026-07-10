# Profiles & Access + Share Invite (QR) — Design

2026-07-10 · [Claude] · Deep-dive for the two "Coming Soon" stubs in More → PEOPLE
(`MoreView.swift` `peopleSection`). Phase 1 (the zero-secret "home-join" invite QR)
ships with this round; Phases 2–4 are designed here and await their own rounds.

## 1. What "access" is today (ground truth)

- Access to a bridge = possessing `(host, application key)`. Each CLIP pairing POST
  (`BridgeDiscoveryViewModel.performPairingRequest`, devicetype `chromaglow#ios`,
  `AppBrand.hueDeviceType`) mints a NEW app key after a link-button press.
- Credentials live per-bridge in Keychain (service `com.lightshade.app`, keys
  `hue_bridge_<uuid>_ip/_token/_clientkey`, shared access group via
  `SharedKeychainStore`). Registry: SwiftData `BridgeRecord`, deduped on the
  canonical 16-hex `bridgeIdentifier` by `BridgePairingRegistrar`.
- TLS: TOFU with identity binding — the pairing trust delegate validates the leaf
  CN == bridgeid and captures a pin (`BridgePinStore`) BEFORE anything persists.
- There is NO user/profile/household entity, NO ACL, NO per-room gating anywhere.
  A Hue app key is all-or-nothing for the whole bridge — that is a platform fact
  every phase below must present honestly.

## 2. Invite architectures compared

| | (A) Per-guest minted key in QR | (B) Owner's token in QR | (C) "home-join" bootstrap QR |
|---|---|---|---|
| Secret in QR | Yes (guest key) | Yes (owner's key) | **None** |
| Link button | Owner, at invite creation | None | Anyone at home, at redemption |
| Bridge-side identity | Distinct per guest | Indistinguishable from owner | Distinct (guest's own pairing) |
| Revocation story | Best available (see §4) | None, ever | Same as A minus owner bookkeeping |
| Owner's key leaves device | No | **Yes — rejected outright** | No |
| Works without physical bridge access at redemption | Yes | Yes | No |

**Decision: hybrid.** Phase 1 ships (C); Phase 2 adds (A) for the
guest-can't-touch-the-bridge case and as the carrier for profile constraints.
(B) is permanently rejected — a photographable, unrevocable copy of the owner's
credential violates the app's entire credential posture.

**QR trust rule (all kinds):** the QR's expected pin (`pinPK`) is *verified
against*, never ingested. The guest device performs its own live TOFU capture +
`/api/0/config` bridgeid cross-check, then additionally requires the captured
public-key hash to equal the QR's. A malicious QR can only cause a refusal — it
can never inject trust. Note: `BridgePin.publicKeySHA256` hashes
`SecKeyCopyExternalRepresentation` bytes (raw key), not SPKI DER — an Android
implementation must hash the same bytes.

## 3. Wire format (Phase 1, shipped)

Same scheme/host as scene sharing (`lightshade://share?d=<base64url(zlib(json))>`),
new envelope `kind` — the codec's `kind` field was designed for exactly this.
Old app versions refuse it gracefully ("This link holds a 'home-join', which this
version can't open").

```json
{
  "join": {
    "bridges": [
      { "bid": "ECB5FAFFFE123456", "host": "192.168.1.23",
        "name": "My Bridge", "pinPK": "<base64 sha256 of leaf public key>", "port": 443 }
    ],
    "homeName": "Brian's Home",
    "issuedAt": "2026-07-10T12:00:00Z"
  },
  "kind": "home-join",
  "v": 1
}
```

~375 B URL for one bridge, ~900 B for four — under `SceneQRRenderer`'s 1200 B
comfortable line; nothing to shrink. `ShareLink` is allowed for home-join
(no secrets). Phase 2's `kind: "invite"` adds `token`, `allowedGroups`,
`features`, `expiresAt` per bridge — display-only QR, time-boxed, NO ShareLink,
and `clientkey` is NEVER in any payload (guest minting uses
`generateclientkey: false`).

Codec: `InvitePayloadCodec` (Core/Share) + `ScenePayloadCodec.probeKind(url:)`
(cheap kind probe so scanners can filter). `DeepLinkCoordinator` routes
`home-join` to `pendingInvite` and **still never saves** — the accept/save is
owned by `InviteAcceptCoordinator` (verify → pair → `BridgePairingRegistrar.register`
→ `addBridge` + `loadAll`). `ScanSceneView` gained an `accepts:` filter; the scene
scanner and the invite scanner refuse each other's QRs.

## 4. Revocation — honest limits

- **Modern bridge firmware removed local whitelist DELETE**
  (`DELETE /api/<key>/config/whitelist/<element>` — long disabled by Signify;
  deletion moved to official-app/cloud). There is no CLIP v2 local API for key
  listing or deletion. Nothing in this repo contradicts that; nothing confirms it
  either — **Phase 4 opens with a hardware spike** on Brian's actual bridge
  (attempt the v1 whitelist read via `GET /api/<key>/config` and the DELETE)
  before any UI copy is finalized.
- What the app can honestly do: (1) attempt the delete and verify by re-read
  (works only on ancient firmware); (2) owner-side wipe — delete the stored guest
  key, mark the profile revoked, refuse to re-show the QR; (3) guest-side
  cooperative wipe on an EXPLICIT bridge "unauthorized user" response (Hue error
  type 1 / 401-403) — the L-30 pattern: active wipe on explicit signal, never
  inferred from network failure.
- Required UI copy: "Removing a guest here deletes their key from this phone and
  blocks re-inviting. Their existing bridge access can only be fully revoked from
  the official Philips Hue app (or by resetting app keys)."

## 5. Profiles model (Phase 2/3)

Owner device — new SwiftData `@Model GuestProfile` (additive schema):
`id, name, icon, colorHex, allowedGroupIDs [String], features [String]
("onOff","brightness","scenes"), createdAt, lastInviteAt?, revokedAt?,
mintedKeyRefs [String]` (Keychain accounts `hue_invite_<profileID>_<bridgeRecordID>_token`
— additive names, no existing key renamed). Guest device — `GuestAccessGrant`
keyed by `BridgeRecord.id` (never mutate BridgeRecord itself): `allowedGroupIDs,
features, grantedProfileName, receivedAt`.

**Enforcement is app-side only and must say so** ("Room limits apply inside
ChromaGlow on this phone. The key itself can control the whole bridge from any
Hue app — a Philips Hue limitation."). One choke point: filter disallowed groups
out of `roomsByBridge`/`zonesByBridge` before `rebuildAllRooms()/rebuildAllZones()`
so dashboard, widgets, watch, and Siri entities all inherit the filter for free.
Tab gating (hide Studio; no create/delete in Scenes) rides `GuestAccessGrant`.
Constraints are advisory + local; the documented "update" path is regenerate +
re-scan an invite (no owner→guest channel exists).

## 6. Phases

1. **Share Invite, home-join QR (THIS ROUND, build 25):** `InvitePayloadCodec` +
   `probeKind`, `ShareInviteSheet` (owner QR from More), `JoinSharedHomeView`
   (guest flow: reachability probe → link-button step → pair with
   `expectedIdentity` check), `BridgeSetupView` "Join a Shared Home" entry,
   `pendingInvite` routing, scanner filters. No Keychain/App Group/payload-shape
   changes. Excludes: profiles, per-guest keys, revocation.
2. **Per-guest app key (arch A):** extract `mintApplicationKey` from
   `performPairingRequest` (shared identity gate); devicetype
   `chromaglow#g-<slug>` (device segment ≤ 19 chars); `generateclientkey:false`;
   `GuestProfile.mintedKeyRefs`; invite-creation flow (profile → rooms →
   link-button → time-boxed QR); guest accept without link button. ~900 lines.
3. **Profiles & Access UI + guest enforcement:** `ProfilesAccessView`
   (BridgeManagerView patterns), `RoomAccessPicker`, orchestrator choke-point
   filter, tab gating, guest banner. ~700 lines.
4. **Revocation:** hardware spike first; `HueV1Client.fetchWhitelist()`
   (H-03 redaction — whitelist keys are other apps' secrets, never logged, shown
   truncated) + best-effort delete verified by re-read; "Keys on this bridge"
   section; guest-side explicit-signal wipe; honest fallback dialogs. ~300–400.

## 7. Security checklist (every phase must pass)

1. No credential ever touches a backend; QR/deep-link is the only transport.
   No universal links (the OS would GET the URL against a server).
2. Secrets in Keychain only (shared group, AfterFirstUnlockThisDeviceOnly,
   non-sync); all new accounts additive; frozen surfaces untouched
   (`persistence-and-credentials.md` do-not-change list).
3. Entertainment `clientkey` never leaves Keychain; guest keys mint without one.
4. No token in logs — extend `SecretLogScrubTests` for invite URLs (Phase 2)
   and whitelist bodies (Phase 4).
5. Pins verified-against, never ingested; pairing keeps live TOFU +
   bridgeid cross-check; fail closed.
6. Owner's own token never serialized into any payload.
7. Token-bearing QR (Phase 2): display-only, time-boxed, regenerable, on-screen
   warning, no ShareLink.
8. Revocation wipes actively on explicit signal only (L-30 / `wc_unpaired`
   precedent).
9. UI states the enforcement truth (app-side limits; bridge-wide key power;
   real revocation path is official Hue tooling).
