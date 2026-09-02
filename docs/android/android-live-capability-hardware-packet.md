# Android Live Capability Convergence — Physical Hardware Test Packet

Prepared by Adam (orchestrator) for Brian, 2026-09-02. Automated/adversarial validation of
`feat/android-live-capability-convergence` is complete; nothing below is proven until Brian observes
it on real bridges and lamps. Record results per row: PASS / FAIL (what happened) / N/A (lamp does
not advertise it). Any FAIL in H9 or H12-C is a merge blocker.

## Provenance (fill-in verified at packet time)

| Field | Value |
|---|---|
| Feature branch | `feat/android-live-capability-convergence` |
| HEAD | `c66205e8f97e62c38aec0280b13fd6dca7859319 (code head; the docs commit on top does not change the APK)` |
| versionCode / versionName | 3 / 1.0 |
| Debug APK path | `android/app/build/outputs/apk/debug/app-debug.apk` |
| APK SHA-256 | `5b6e93098ee82f6ea9a1b8a148e76e699aac948cd67678ef11d2460c76cff861` |
| Build command | `cd android && ./gradlew clean lintDebug testDebugUnitTest assembleDebug` (JDK 21 at `/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home`) |
| Install | `adb install -r android/app/build/outputs/apk/debug/app-debug.apk` then confirm Settings → About shows 1.0 |

Verify before installing: `shasum -a 256 android/app/build/outputs/apk/debug/app-debug.apk` must
equal the SHA above. Do not test a different build.

## Connected suite (Brian runs; not executed by the agents)

```
cd android
adb devices -l            # exactly one intended device/emulator (Pixel_10 or the phone)
./gradlew connectedDebugAndroidTest
```
Record total / passed / failed / skipped and any failing class#method. Expected suites: Setup
pairing flow, Keystore credential store, and the Compose suites for Home, Group detail, Light
detail, Scenes, Settings, components (46 UI tests compile but were never executed by the agents).

## Ordered checklist

**H0 — Pairing and persistence (bridge A)**
1. Launch the installed APK; confirm About shows 1.0 and the build is the SHA above.
2. Tap Pair before pressing the link button → "press the link button" message (type 101), Pair button returns, no auto-retry.
3. Press the link button, tap Pair → Home appears with rooms/zones (no Setup flash, no demo content).
4. Kill and relaunch → lands on Home directly.
5. Settings → Forget (confirm) → Setup; relaunch → still unpaired.

**H-PROBE — bridge resource diagnostic (both bridges)**
6. Pair each bridge in turn; with `adb logcat -s ChromaGlow` note the redacted `bridge probe` line: field presence/shape of `/clip/v2/resource/bridge` and the casing of `bridge_id`. Do NOT expect any refusal from it; it is diagnostic only.

**H3 — per-light scrub**
7. Light detail on one lamp: scrub brightness continuously for 20 s. Lamp follows smoothly, no snap-backs, no "Couldn't change" Snackbar.

**H4 — network loss / recovery**
8. Unplug the bridge for 30 s: strip shows Stale with age, then Offline; controls disable with a spoken reason (TalkBack optional). Plug back in: Connected within 60 s, one refresh, no duplicate streams (single `SSE connected` in logcat).

**H5 — external change via SSE**
9. Change a light in the Hue app → card follows within ~1 s.

**H6 — no echo flap**
10. With the Hue app open, toggle and dim from Android; Android card must not flicker back to the old value.

**H7 — background/foreground**
11. Background the app 5 min, foreground: exactly one refresh, stream reconnects, values current.

**H8 — offline relaunch from cache**
12. Bridge unplugged, kill and relaunch: cached rooms paint marked Stale; no token loss (plugging in returns to Connected without re-pair).

**H9 — interactive flash ceiling (60 fps video)**
13. Film the lamp at 60 fps while scrubbing brightness as fast as possible, toggling on/off rapidly, switching scenes rapidly, and alternating a bright and a dim scene. No two ≥10% luminance rises closer than 20 frames (0.34 s). Also: room slider then a single light slider alternately.

**H11 — capability truth per lamp class**
14. White-only lamp: only brightness; no colour/warmth/effects/gradient sections.
15. CT lamp: Warmth range equals the lamp's mirek_schema; no colour pad.
16. Colour lamp: colour pad over its gamut; effects chips = `effect_values`.
17. Gradient strip: swatch count = `points_capable`; mode chips = `mode_values`.
18. A lamp reporting CT without a schema (if any): section shows CHECKING, not a control.
19. Room with mixed lamps: group Colour/Warmth show "Applies to N of M lights" with correct N.

**H12 — promoted native capabilities (where advertised)**
20. Effects: chips match `effect_values`; select each; speed low and high; effect colour; effect mirek; no_effect stops.
21. v1-only lamp (if present): fallback chip set works.
22. Timed: sunrise and sunset start; duration honoured (15 min shortest in UI); cancel works; starting timed while a firmware effect runs clears the effect.
23. Gradient: points, mode, count = points_capable, visible colour result.

**H12-C — EFFECT CADENCE SAFETY (mandatory)**
24. At 60 fps film every advertised effect at low and high speed on every lamp/firmware class. Any qualifying onset pair < 20 frames apart: record effect id / lamp model / firmware, add the id to `EffectSafetyRegister` (core/session/safety), rebuild, confirm the chip is hidden. Merge blocker until done.

**H13 — scenes**
25. Activate a scene → Activating → Active; activate the same scene from the Hue app → Android shows Active; delete a scene in the Hue app then tap it → failure Snackbar and row removed on refresh.

**H14 — external revocation**
26. Remove the app key in the Hue app: Android shows "Access removed" / Revoked, record kept, Settings offers Forget; nothing auto-wiped; re-pair from Setup works.

**H16 — accessibility**
27. TalkBack: cards read name + state; faders announce range and value; chips announce selected; connection changes are announced. 200% font: every screen scrolls, nothing clipped. Remove animations: no motion.

**H17 — notice**
28. Open Light detail on an effects-capable lamp: notice shown once; acknowledge; navigate away and back, kill and relaunch: not shown again.

**Conditional (developer-preprovisioned second bridge; no Pair-another UI in this slice)**
29. H1 both bridges restored at launch; H2 back-to-back toggles per bridge; H10 two bridges lighting one room (record only); H15 Forget bridge 1 while bridge 2 stays live.

## Mutation feedback checks (added this round)
30. Unplug the bridge mid-drag: "Couldn't change … — reverted" or "Couldn't confirm — refreshing" Snackbar appears; never a silent old value.
31. Pick a deny-listed or unsupported effect (if configured): refused Snackbar, no PUT in logcat.
