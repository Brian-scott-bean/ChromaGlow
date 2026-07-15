# ChromaGlow — App Store Submission Runbook

Written 2026-07-11 by Claude, from the App-Store-readiness audit (research + codebase sweep + design pass).
Everything in **Part A** was already done in the `checkpoint/appstore-prep-2026-07-11` commit run.
**Part B** is the step-by-step for the things only Brian can do (App Store Connect + Xcode Organizer).

---

## Part A — Code/config state (done in the 2026-07-11 prep run)

| Item | State |
| --- | --- |
| Built with iOS 26 SDK (Apple mandate since 2026-04-28) | ✓ Xcode 26.3/26.4 |
| `ITSAppUsesNonExemptEncryption=false` (export compliance pre-answered) | ✓ `HueHome/Info.plist` |
| Usage descriptions: local network, Bonjour `_hue._tcp`, camera, mic, location | ✓ all present |
| ATS minimal (`NSAllowsLocalNetworking` only, no arbitrary-loads) | ✓ |
| Privacy manifests in all four bundles (app, widget, watch ext, watch app) | ✓ verified in built products — see False-Positive note below |
| No third-party SDKs, analytics, accounts, IAP, private APIs | ✓ |
| Demo mode reviewer-usable with zero Hue hardware | ✓ "Explore Demo" on first launch |
| Nothing user-visible leads with "Hue" (alt app name + widget label fixed) | ✓ prep run |
| Signify non-affiliation disclaimer (More + Settings + privacy policy) | ✓ prep run |
| One-time photosensitivity notice on first Studio entry | ✓ prep run |
| Release builds print no Composer/PERF console diagnostics | ✓ prep run + build-28 audit (35 more sites gated: StudioViewModel/CompositionStore/WatchStore; sweep clean across all 4 targets) |
| Version 1.0.0 (build 28) | ✓ prep run; bumped to 28 in the build-28 audit + Welcome Tour round |
| Privacy policy + support pages current (camera/location added, beta wording removed) | ✓ prep run |

**⚠️ False-positive warning for future agents:** the widget/watch targets have EMPTY Resources
build phases in `project.pbxproj` **by design** — this project is `objectVersion = 70` and those
targets use `PBXFileSystemSynchronizedRootGroup` (folder-synchronized membership, computed at
build time). Their `PrivacyInfo.xcprivacy` and asset catalogs DO ship; this was verified against
built DerivedData products (`assetutil --info` shows the watch AppIcon; the `.appex`/`.app`
bundles each contain `PrivacyInfo.xcprivacy`). Do **not** "fix" this by adding explicit
Resources-phase entries — that creates duplicate membership and a
"Multiple commands produce…" build failure.

---

## Part B — Brian's steps, in order

### B1. App Store Connect housekeeping (~15 min)

1. Sign in at appstoreconnect.apple.com → My Apps → **ChromaGlow** (Apple ID `6766251782`).
   Confirm the record's bundle ID is `com.huehome.pro` and status is "Prepare for Submission".
2. The old listing (`6765770802`) — leave it; never upload to it. Optionally delete the record
   if ASC allows (only possible if it never had an approved version).
3. Business → confirm the **free-app agreement** (Apple Developer Program License Agreement)
   is accepted and no agreement banners are pending. Free app → no paid-apps contract/banking
   needed.

### B2. Compliance questionnaires (~20 min)

1. **Age rating** — App Information → Age Rating → complete the questionnaire (it changed
   January 2026; you must answer the new version). Nothing in ChromaGlow triggers a
   restriction: expect **4+**.
2. **Privacy nutrition label** — App Privacy section. Privacy Policy URL:
   `https://brian-scott-bean.github.io/ChromaGlow/privacy.html`
   Then answer the data-collection questionnaire: **"Data Not Collected"** — every category No:
   no data is collected *by the developer* (mic/camera are processed on-device and never leave
   the phone; bridge credentials stay in the local Keychain; no analytics, no accounts, no ads,
   no tracking). "Collected" in Apple's definition means transmitted off-device to you or your
   partners — nothing in ChromaGlow is.
3. **EU trader status (DSA)** — required declaration regardless of where you distribute.
   - **Non-trader** (hobbyist, non-commercial): nothing published; simplest. A free app with
     no monetization plausibly qualifies, but the definition keys on whether the activity is
     commercial — if you plan to monetize later, expect to re-declare as a trader then.
   - **Trader**: Apple verifies and **publicly displays** an address, phone, and email on the
     EU product page.
   - Either way you can also simply **deselect EU territories** in Pricing & Availability for
     v1.0 and decide later.
4. **Export compliance** — nothing to do at submit time: `ITSAppUsesNonExemptEncryption=false`
   is in the Info.plist (app uses only OS TLS — exempt), so ASC won't prompt per build.

### B3. Store metadata (~30 min, drafts below — edit to taste)

- **Name:** ChromaGlow (locked already)
- **Subtitle** (30 chars max): `Scenes & FX for Philips Hue` (27 — nominative "for Philips
  Hue" is the accepted third-party pattern)
- **Promotional text** (170 max):
  `Paint your rooms with light — scenes, music-reactive effects, widgets, watch app, and
  family sharing for your Philips Hue lights. Local-first: no account, no cloud.`
- **Description** (draft):

  > ChromaGlow is a fast, private, local-first controller for your Philips Hue lights.
  >
  > Everything happens on your own Wi-Fi — no account, no cloud, no tracking. Your bridge
  > credentials never leave your device.
  >
  > • DASHBOARD — every room and zone, instant on/off, brightness, and color
  > • SCENES — browse, activate, create, copy between rooms, share by QR code
  > • STUDIO — 56 built-in dynamic compositions plus a full composer: layered palettes,
  >   spatial motion, and music-reactive effects driven by your microphone (processed
  >   on-device, never recorded)
  > • PERFORM — a live pad surface for punching effects in real time
  > • WIDGETS & CONTROL CENTER — scenes and room controls on your Lock Screen and Home Screen
  > • APPLE WATCH — rooms, scenes, and presets on your wrist
  > • SIRI — "Turn on the kitchen in ChromaGlow", named colors, scenes, and presets
  > • FAMILY SHARING — invite housemates by QR code with per-person room access, no accounts
  > • AUTOMATIONS — schedule scenes with local notifications, including sunrise/sunset
  >
  > Requires a Philips Hue Bridge (v2) on your local network. Try every feature first with
  > the built-in Demo Mode — no hardware needed.
  >
  > ChromaGlow is an independent app and is not affiliated with, endorsed by, or a product of
  > Signify (Philips Hue). Philips Hue is a trademark of Signify Holding.

- **Keywords** (100 max, comma-separated, no spaces needed after commas):
  `hue,lights,lighting,smart home,scenes,color,ambiance,music,sync,led,mood,bridge,lamp`
  ("hue" doubles as a generic color word and is defensible; do NOT put "philips" in keywords.)
- **Support URL:** `https://brian-scott-bean.github.io/ChromaGlow/`
- **Marketing URL** (optional): same, or leave blank.
- **What's New:** `Initial release.`
- **Category:** Primary **Lifestyle** (Philips Hue's own category); Secondary **Utilities**.
- **Pricing & Availability:** Free; pick territories (see trader-status note above).

### B4. Screenshots (~1–2 hrs, the biggest manual chunk)

Minimum one set per device class you ship (up to 10 each). Capture from simulators with real
demo-mode content (⌘S saves a correctly-sized PNG). Suggested shots: Dashboard, Room detail
(color pad open), Scenes tab, Studio (composition running), Perform pads, widget gallery /
Lock Screen, watch app rooms + scenes.

| Class | Simulator | Size |
| --- | --- | --- |
| iPhone 6.9" (required) | iPhone 17 Pro Max | 1320×2868 |
| iPad 13" (required — iPad support is kept) | iPad Pro 13" (M4) | 2064×2752 portrait |
| Apple Watch (required — watch app included) | largest current watch | per current ASC spec (e.g. 410×502 Ultra / 396×484 46mm) |

Reference: developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/

**iPad QA smoke first**: run the app on the iPad Pro 13" simulator and walk Dashboard → Room →
Scenes → Studio → More. The reviewer may test on iPad; layouts must hold up before you
screenshot them.

### B5. Build & upload (~30 min)

1. In Xcode: select the **"HueHome 1"** scheme → destination **Any iOS Device (arm64)**.
2. Product → **Archive** (Release config; version should read 1.0.0 (28)).
3. Organizer → Distribute App → **App Store Connect** → Upload (automatic signing; team
   `2H9J347H3T`). Provisioning auto-creates as before (`-allowProvisioningUpdates` precedent).
4. Wait for processing (~15 min), then in ASC → TestFlight, install build 28 on your phone and
   watch; smoke the two-phone family-sharing checklist and the build-24–26 on-device items
   still pending from the DEVLOG.
5. In the ASC version page, select build 28.

### B6. Review notes + demo video (the make-or-break item)

App Review → App Review Information:

- **Notes** (draft):

  > ChromaGlow controls Philips Hue smart lights entirely over the local network via the
  > user's Hue Bridge (official CLIP v2 API). No account or sign-in exists.
  >
  > REVIEWING WITHOUT HUE HARDWARE: on first launch tap **"Explore Demo"** — the full app
  > (rooms, scenes, Studio effects, widgets data, watch app) runs against built-in simulated
  > bridges. No permissions are required in demo mode. A one-time 12-page Welcome Tour
  > appears on first entry (Skip or swipe through; replayable from More → "Replay the Tour").
  >
  > On real hardware: local-network + Bonjour permission is requested at bridge discovery;
  > microphone only when starting a music-reactive preset (audio is analyzed on-device,
  > never recorded); camera only inside the QR-scan screens (scene sharing / home invites);
  > location once, only for sunrise/sunset automations.
  >
  > The attached video shows the app pairing with and controlling a physical Hue Bridge.

- **Attachment**: record a 1–2 min iPhone screen recording controlling your real lights
  (pairing prompt, room on/off, a scene, a Studio effect), AirDrop it to the Mac, attach.
- Contact info: your phone + email. Sign-in required: **No**.

### B7. Submit & what to expect

- Submit for Review. Typical first response: 24–48 h.
- Most likely rejection vectors and the prepared answer:
  1. **"We couldn't verify app functionality" (2.1)** → reply pointing to Demo Mode + the
     video; offer a live call if needed.
  2. **Metadata/trademark question (5.2)** → the app is an independent controller using
     Signify's public local API; nominative "for Philips Hue" wording; disclaimer is in the
     app and description; nothing is branded "Hue".
  3. **Local-network permission question** → it is the app's core function (bridge is a
     local-network device); usage string explains it.
- If rejected, respond in Resolution Center rather than re-submitting blind — reviewers
  usually accept a clear explanation.

### Risk register (accepted, eyes-open)

- **"ChromaGlow" name collisions**: Apple's Logic Pro has a "ChromaGlow" plug-in feature;
  Big Star Lights sells a "Chromaglow Controller" (lighting hardware). Accepted risk; keep
  evidence of first use. A forced rename post-launch is possible but unlikely.
- **Bundle ID `com.huehome.pro` contains "hue"** — immutable post-release, never user-visible;
  fine.
- **watchOS 26.4 deployment floor** limits the watch app to current watches (deliberate).
- **URL scheme `lightshade://`** — historical, user-invisible except in QR payloads; fine.

### Appendix — later cleanup (not blocking, do not do during submission)

- Stale `ChromaGlow.xcodeproj/` husk (no pbxproj) + stray `ChromaGlow/UI/` folder + historical
  `generate_xcodeproj.rb`/`fix_assets_path.rb` scripts at repo root.
- `run_tests.sh` stale `SCHEME="HueHome"` (pass `-scheme "HueHome 1"` manually).
- Dead `isPro` field on the SwiftData `AppSettings` model (schema-migration implications —
  remove only with a deliberate migration).
