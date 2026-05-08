# ChromaGlow Development Log

> **AI assistants: Append to this file after every session. Read it at the start of every session.**

---

## 2026-05-07 — Multi-Bridge Concurrent Entertainment Sessions (Antigravity)

### What was built

Upgraded the entertainment transport layer from a single-session global to a **per-bridge dictionary**, enabling concurrent DTLS sessions across multiple Hue bridges simultaneously.

#### Root cause
The old guard `compositionEntRoomID == nil` was global — starting entertainment on Bridge A blocked Bridge B from ever using DTLS, silently falling back to choppy REST.

#### Changes
All single-slot state replaced with `[bridgeID: ...]` dictionaries:

| Old | New |
|---|---|
| `compositionEntTask: Task?` | `compositionEntTasks: [String: Task]` |
| `compositionEntRoomID: String?` | `compositionEntRoomByBridge: [String: String]` |
| `compositionEntertainmentParamBox` (weak) | `compositionEntParamBoxes: [String: CompositionParamBox]` |
| `studioEntClient: HueEntertainmentClient?` | `studioEntClients: [String: HueEntertainmentClient]` |
| `activeEntertainmentConfig: EntertainmentConfig?` (stored var) | `entertainmentConfigsByBridge: [String: EntertainmentConfig]` + `activeEntertainmentConfig(for: RoomDisplayItem?)` method |

#### Impact
- **2 bridges = 2 simultaneous DTLS sessions = 20 smooth channels**
- Single-bridge behavior unchanged (dictionary has one entry)
- StudioView mini-map and direction dial now read config for the **currently selected room's bridge** — correct when switching between bridge rooms
- Mic demand check updated to `anyOf` across all active param boxes
- Stop path looks up bridgeID from roomID → cleans only that bridge's session

### Files changed
| File | Change |
|---|---|
| `UnifiedOrchestrator.swift` | Dictionary state, per-bridge guard, start/stop/cleanup paths |
| `StudioView.swift` | `activeEntertainmentConfig(for:)` at 4 call sites |
| `StudioViewModel.swift` | `studioEntClients[bridgeID]` at 2 call sites |

### Git state
- Commit: `f2f360b` on `main`
- BUILD SUCCEEDED

### How to test
1. **Single-bridge regression:** Start entertainment composition → verify `⚡ Entertainment transport active` log → stop → verify no crash
2. **Multi-bridge:** Pair two bridges, both with entertainment areas → start composition on each → both should log `⚡` with different bridgeIDs → mini-map switches correctly when navigating between rooms

---

## 2026-05-07 — Transport Architecture Research (Antigravity)

### What was investigated

Deep dive into why 16-light REST compositions show "room by room" sequential updates.

#### Root cause
REST per-light mode batches 5 PUTs with 80ms gaps → ~1.1s to cycle all 16 lights per frame. Not a code bug — a fundamental HTTP rate-limit constraint.

#### Transport tiers (current architecture)
```
Entertainment (DTLS)   → 25fps, all lights simultaneously, 10 channel limit, 1 session/bridge
REST per-light         → ~10 PUTs/sec, batches of 5, choppy on 8+ lights
Bridge v1 rules chain  → 3s min step interval, app-free, bridgeOptimized presets only
V2 Dynamic Palette     → bridge firmware cycles palette, unlimited lights, smooth, app-free
```

#### V2 Dynamic Palette — key findings
- Create scene with `palette.color[]` array + `speed` + `auto_dynamic: true`
- Recall with `action: "dynamic_palette"`
- **Bridge firmware handles cycling on the light itself** — zero ongoing network traffic
- Unlimited lights (whole room via grouped_light), persists after app close
- Trade-off: no directional patterns (wave/cascade/mirror), no envelope shapes, no mic
- `BridgeAnimationEngine.uploadV2DynamicScene()` already exists but is **not wired to the composer flow** and missing the `palette` property on `CreateSceneRequest`

#### What's not yet built
- [ ] `CreateSceneRequest` needs `palette` property (`color[]`, `color_temperature[]`, `speed`, `auto_dynamic`)
- [ ] `uploadV2DynamicScene` should use composer palette colors (not single t=0 snapshot)
- [ ] Wire into `startCompositionMode` as a transport tier between DTLS and REST
- [ ] "Persist on Bridge ⚡" toggle in mixer tray
- [ ] Cleanup on stop (delete dynamic scene from bridge)

### What's next
- [ ] Implement V2 Dynamic Palette as a composer transport tier
- [ ] Map `motion.speed` (0–100) → Hue `speed` (0.0–1.0)
- [ ] Badge on room card when bridge-powered effect is active

---

## 2026-05-07 — Codebase Audit: Architecture, Risks, Follow-ups (Cursor)

### What was reviewed
Thorough pass over critical paths (no line-by-line coverage of every file): `UnifiedOrchestrator`, `HueAPIClient`, Studio/Composer wiring, `RoomDisplayItem`, SSE/optimistic merge, `MainTabView` shell, cold-launch changes, logging patterns.

### Positive findings (keep)
- `pendingActionDeadlines` for SSE vs optimistic grouped_light updates reduces toggle flicker.
- Direct `allRooms` mutation in `updateRoom` with documented `@Observable` rationale.
- Composer generation guards, RestSender mailbox, entertainment vs REST split align with bridge reality.
- `RoomDisplayItem` uses full-field `==` (not id-only) so SwiftUI sees on/brightness/dominant color changes.
- Hue self-signed cert handling documented for session + task delegate (iOS 15+).

### Issues / edge cases (prioritized)
**High — reconcile docs vs code**
- `.cursorrules` says never send `effects` to `grouped_light`; `HueAPIClient` + `EffectsViewModel` intentionally use `setGroupedLightNativeEffect` for bridge-native effects. Clarify rule (Composer/custom vs firmware native) in `.cursorrules` / `DEVDOC.md` to avoid wrong “fixes.”

**High — correctness**
- Deprecated `toggleRoom`: rollback uses captured `item.isOn` on failure — stale if state moved; prefer removal or rollback by reading current room by id (`UnifiedOrchestrator`).
- `RoomDisplayItem`: `hash(into:)` mixes fewer fields than `==` uses — `Hashable` contract risk if identity-related fields change without hash updates.

**Medium**
- `StudioViewModel`: many `print(...)` calls on apply/handoff/AI paths — migrate to `Logger` + `#if DEBUG` or privacy-redacted `os_log` for release.
- Concurrent `loadAll`: second caller hits guard and returns early — confirm refresh UX is acceptable.
- Parallel `loadAll`: `deactivateStuckEntertainmentSessions` + fetch overlap — brief window where data loads before stuck session cleared; monitor if odd throttle on cold launch.
- SwiftData: `fatalError` on container init — no recovery path (acceptable for corrupt DB but worth knowing).

**Lower**
- MainTabView tab prewarm: trades idle memory for snappy first switch; optional tuning on low-memory devices.
- Legacy branding strings (“CastChroma”) still in some file headers — cosmetic.

### What's left
- [ ] Update `.cursorrules` / `DEVDOC` for grouped_light native effects vs Composer effects.
- [ ] Fix `RoomDisplayItem` hashing to align with `Equatable`, or document exception.
- [ ] Remove/fix deprecated `toggleRoom` rollback or delete call sites.
- [ ] Replace Studio `print` with structured logging for release builds.

### Gotchas
- Audit did not include full Keychain/remote OAuth review or device QA against a live bridge.

### Current state
No code changes from this audit entry alone — documentation and small correctness fixes deferred to follow-up tasks.

---

## 2026-05-07 — Cold-Launch First Tab Switch: Prewarm + Parallel loadAll (Cursor)

### What was built

**MainTabView — deferred-tab prewarm**
- After Home paints, stagger inserting `.studio`, then `.scenes` / `.more` into `realizedTabs` (~280ms + ~160ms) so heavy roots (`StudioView`, etc.) compile off the first-tab-tap critical path.
- `.task { await prewarmDeferredTabs() }` on the shell `Group` (iPhone + iPad).

**UnifiedOrchestrator — loadAll**
- `deactivateStuckEntertainmentSessions()` and bridge fetch/merge now run **in parallel** via outer `withTaskGroup` (cleanup no longer gates room data).
- Extracted `fetchAndMergeAllBridges()` (previous inner task-group body).
- `await Task.yield()` before `rebuildAllRooms()` / `rebuildAllZones()` so pending UI work can run before large `allRooms` / `allZones` observable updates.

### What's working
- ✅ `xcodebuild` HueHome — BUILD SUCCEEDED

### What's left
- [ ] Device QA: confirm first Studio tap feels instant; watch memory with all tabs realized.
- [ ] Instruments (Time Profiler + SwiftUI) if any hitch remains — optional further split of `StudioView`.

### Gotchas
- Tapping Studio within ~280ms of launch may still pay cold-build cost (edge case).
- Prewarm realizes all lazy tabs → higher idle memory; trade for snappy navigation.

### Current state
Cold-launch tab responsiveness addressed by idle prewarm + shorter loadAll critical path; ready for on-device timing validation.

---

## 2026-05-07 — Audit Bugfixes: 3 Bugs in Spatial Engine (Antigravity)

### What was changed

Post-implementation audit found 3 bugs in the Spatial Motion Engine. All fixed and verified with clean build.

#### Bug #1 — REST Spatial Positions Never Worked (Critical)
- **Root cause:** `computeSpatialPositions()` used `channel.lightServiceIDs` as map keys, but these are **entertainment** service IDs (from `/clip/v2/resource/entertainment_configuration` → `members[].service.rid`), NOT `light` service IDs. REST `compositionLightIDs` come from `fetchLights().map { $0.id }` — different UUID namespace. Lookup always returned nil → silent fallback to index-based.
- **Fix:** Added `resolveEntertainmentLightPositions()` to `UnifiedOrchestrator`. Fetches `/clip/v2/resource/entertainment` services in parallel with lights, builds the bridge: `entertainment_service_id → device_id → light_id`. Changed `computeSpatialPositions()` to accept pre-built `lightPositions: [String: (x: Double, z: Double)]` map instead of raw `EntertainmentConfig`.

#### Bug #2 — Mirror Toggle Did Nothing on Index Path
- **Root cause:** `phase(lightIndex:total:time:)` never read the `mirror` field. Only the spatial overload `phase(spatialPosition:time:)` applied `abs(position - 0.5) * 2.0`.
- **Fix:** Added `if mirror { position = abs(p - 0.5) * 2.0 }` to the index-based function.

#### Bug #3 — PCA Overrides User's 0° Angle
- **Root cause:** `motionAngle` defaulted to `0`. Orchestrator checked `== 0` to decide whether to auto-detect. But 0° (→ rightward) is a valid user choice.
- **Fix:** Changed default to `-1` (sentinel = "auto-detect"). Check changed to `< 0`. UI clamps display to `max(0, angle)`.

### Files changed
| File | Change |
|---|---|
| `CompositionEngine.swift` | `computeSpatialPositions` now takes `lightPositions` map, not `config` |
| `UnifiedOrchestrator.swift` | +`resolveEntertainmentLightPositions()` (~60 lines), PCA check `< 0` |
| `CompositionModels.swift` | `motionAngle` default `-1`, mirror in index `phase()` |
| `StudioView.swift` | `max(0, angle)` at 4 UI read points |

### Git state
- All work merged to `main` (commit `6c8eb87`)
- Feature branch `feature/harmony-spatial-engine` deleted locally, still on remote
- Safe revert point: `7db5c1e` (pre-harmony/spatial, settings cleanup only)

### Known performance issue (not yet fixed)
- **First tab switch takes ~4-5 seconds** after cold launch. Likely causes:
  1. `StudioView` is ~2800 lines — first SwiftUI build is expensive
  2. Synchronous `rebuildAllRooms()` / `rebuildAllZones()` on `@MainActor` blocks UI during large `@Observable` diffs
  3. `deactivateStuckEntertainmentSessions()` runs sequentially before data load
- **NOT caused by** `await` blocking the main thread (Swift concurrency yields on `await`)
- Needs Instruments profiling (Time Profiler + SwiftUI) to confirm bottleneck split

### What's next
- [ ] Performance optimization: move heavy work off `@MainActor`, investigate StudioView cold build cost
- [ ] Test harmony + spatial features on device with bridge
- [ ] Test entertainment area creation flow end-to-end

---

## 2026-05-07 — Spatial Motion Engine (Antigravity)

### What was changed

Upgraded the Composer Motion Layer from array-index-based patterns to physical spatial coordinates. Wave, Cascade, and Bounce patterns now sweep across lights based on their actual positions in the room, not their arbitrary discovery order.

#### Spatial Math (`CompositionEngine.swift`)
- Added `computeSpatialPositions(config:orderedLightIDs:motionAngle:)` — projects entertainment channel positions onto a 2D direction vector via dot product, returns positions ordered to match REST lightIDs (fixes ordering mismatch between entertainment channels and REST resolution order).
- Added `computeSpatialPositionsForEntertainment(channels:motionAngle:)` — same math but returns in channel order for DTLS transport.
- Added `principalAngle(channels:)` — PCA via 2×2 covariance matrix eigenvector to auto-detect the axis of maximum light spread. Used as default `motionAngle` when user hasn't set one.
- Added lerp system (`targetSpatialPositions` + `spatialLerpProgress`) for smooth 0.3s transitions when angle changes.
- Render loop updated: uses spatial `phase()` when positions available, falls back to index for scatter pattern (which needs pseudo-random seeding by index).

#### Model (`CompositionModels.swift`)
- Added `motionAngle: Double = 0` to `MotionConfig` (migration-safe Codable default).
- Added `phase(spatialPosition:time:)` overload — same switch/case logic as index-based version, replaces `lightIndex/total` with pre-computed 0–1 position. Mirror support: `abs(spatialPosition - 0.5) * 2.0`.

#### Orchestrator Wiring (`UnifiedOrchestrator.swift`)
- Fetches entertainment config BEFORE transport decision — both REST and DTLS paths get spatial positions.
- Moved `resolveCompositionLightIDs` earlier to feed the REST-ordered position computation.
- Added `activeEntertainmentConfig: EntertainmentConfig?` (public, @Observable) — exposed for Studio UI mini-map and direction dial.
- Auto-detects principal angle on first launch.
- Clears `activeEntertainmentConfig` on composition stop.

#### Direction UI (`StudioView.swift`, ~280 lines)
- **Direction presets**: 8 arrow chips (→ ↗ ↑ ↖ ← ↙ ↓ ↘), amber-highlighted when selected.
- **Angle dial**: 80pt glassmorphic circle with drag-to-rotate, amber indicator line, 5° snap, haptic ticks at 45° boundaries.
- **Spatial mini-map**: 80pt rounded rect showing light dots at physical (x,z) positions with palette-derived colors + dashed amber direction arrow.
- **Entertainment area prompt**: When no entertainment config exists, shows a styled button that opens `EntertainmentConfigBuilderView` as a sheet. On creation, spatial positions are computed immediately.
- **recomputeSpatialPositions()**: Called from Binding setters (NOT onChange — CompositionParamBox is not @Observable). Triggers smooth lerp + REST burst.
- **Mirror toggle** added to motion controls.
- Direction UI hidden for scatter pattern (non-directional).

### Bugs prevented by audit (6 found before implementation)

| # | Bug | Prevention |
|---|---|---|
| 1 | Scatter breaks with spatial positions (becomes smooth wave) | Render loop skips spatial for `.scatter` |
| 2 | `onChange` on motionAngle never fires | Use Binding setters, not onChange |
| 3 | Entertainment config only fetched on DTLS path | Fetch before transport decision |
| 4 | REST light ordering mismatch (wrong position per light) | lightID→position lookup map |
| 5 | "L → R" direction labels misleading | Arrow symbols + mini-map |
| 6 | Static pattern excluded from dial | Show for all except scatter |

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Models/CompositionModels.swift` | +`motionAngle`, +spatial `phase()` overload |
| `HueHome/UI/Studio/CompositionEngine.swift` | +spatial fields on ParamBox, +4 static helpers, +lerp in render loop |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | +`activeEntertainmentConfig`, spatial wiring, moved lightID resolution |
| `HueHome/UI/Studio/StudioView.swift` | +direction presets, +angle dial, +mini-map, +entertainment prompt |
| `HueHome/UI/Studio/StudioViewModel.swift` | Cleanup (moved property to orchestrator) |

### What's next
- [ ] Test spatial sweep in simulator with multi-light entertainment area
- [ ] Consider expanding to 3D direction (include Y/height axis)
- [ ] Auto-suggest optimal direction based on pattern + light layout

---

## 2026-05-07 — Harmony Engine → Studio Composer (Antigravity)

### What was changed

Integrated the existing `HarmonyEngine` (from SceneBuilder) into the Studio Composer Palette tab. Users can select a harmony rule (Analogous, Triadic, Complementary, Split Complementary, Monochromatic) and drag the 2D hue/saturation pad to generate mathematically harmonious 3-color palettes in real-time.

#### Features
- **Conditional harmony UI**: Chips only appear in `.solid` or `.gradient` modes and only when the current room/zone contains at least one color-capable bulb.
- **Mode awareness**: Auto-clears `activeHarmonyRule` when switching to non-color modes (Spectrum/Temp).
- **Swatch editing**: Tappable preview row → ColorWheelView popover for fine-tuning individual harmony colors.
- **Persistence**: `harmonyRule: String?` on `PaletteConfig` (migration-safe optional).
- **User guidance**: Contextual hint ("Try Cascade or Wave…") when harmony is selected with static motion.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Components/HueColorUtils.swift` | +`codableColor(from:gamut:)` helper |
| `HueHome/Core/Models/CompositionModels.swift` | +`harmonyRule: String?` to `PaletteConfig` |
| `HueHome/UI/Studio/StudioViewModel.swift` | +`roomHasColorLights`, +`restoredHarmonyRule` |
| `HueHome/UI/Studio/StudioView.swift` | +chip row, +swatch preview, +editing popover, +harmony-aware drag |

---

## 2026-05-07 — Settings Consolidation + Navigation Cleanup (Antigravity)

### What was changed

#### Settings is now exclusively in More
- Removed the gear (⚙) toolbar button and its associated `showSettings` sheet from **5 tabs**: Dashboard, Studio, Scenes, Effects, Sync.
- Settings is now accessed from **More → Settings** only — consistent with the iOS Settings app convention.
- `MoreView` is the single owner of `showSettings` state. No other tab manages it.

#### Duplicate content removed from SettingsView
- Removed the `exploreSection` (Automations + Devices navigation links) from `SettingsView`.
- These already exist in `MoreView`'s CONTROL section linking to the same destination views (`AutomationsView`, `DevicesView`). Having them in both places caused confusion.
- **Settings now contains:** Bridges, All Day Scenes, Account (API Token), Developer (Demo Mode + Clean Bridge), App info.
- **More now contains:** Automations, Devices & Firmware, Accessories, Profiles & Access, Share Invite, Bridge Manager, Connection status, Settings (link), Demo Mode, App version.

#### SyncModeView toolbar cleanup
- The `toolbarItems` `@ToolbarContentBuilder` was left empty after removing the gear button. Removed the property and the `.toolbar { toolbarItems }` call entirely rather than leaving a dead no-op.

### Files changed
| File | Change |
|---|---|
| `HueHome/UI/Dashboard/DashboardView.swift` | Removed `showSettings` state, `.fullScreenCover`, gear `ToolbarItem` |
| `HueHome/UI/Studio/StudioView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Scenes/ScenesTabView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` |
| `HueHome/UI/Effects/EffectsView.swift` | Removed `showSettings` state, `.sheet`, gear `ToolbarItem` (bookmark + stop toolbar items untouched) |
| `HueHome/UI/Sync/SyncModeView.swift` | Removed `showSettings` state, `.sheet`, entire `toolbarItems` property + `.toolbar` call |
| `HueHome/UI/Settings/SettingsView.swift` | Removed `exploreSection` property and its call in body |

### What's working
- Settings is reachable from one place (More tab) — no more gear icon on every tab
- No duplicate Automations/Devices entries between More and Settings
- Sync tab toolbar is clean (no leftover empty builder)

### What's next
- [ ] Harmony engine integration into Studio card color pickers (hue strip + rule chip row)
- [ ] "Run on Bridge" opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button already in Settings/Developer — needs soak test

---

## 2026-05-07 — Bridge Animation Fixes + Composer Dynamic Effects Restored (Antigravity)

### Problems fixed (4 bugs, 1 session)

#### 1. Schedule creation failing — error type 6 `"parameter, autoDelete, not available"`
- `HueV1Client.createRecurringSchedule()` was sending `"autodelete": autoDelete` in the POST body.
- Bridge firmware rejects this key with error type 6. Removed it — omitting defaults to `false` (schedule persists).

#### 2. Schedule command using wrong address format
- `sensorIncrementCommand()` returns a **relative** path (`/sensors/{id}/state`), correct for **rule actions**.
- Schedule `command.address` must be the **full** path `/api/{token}/sensors/{id}/state` — the bridge does NOT append user context for schedule commands (unlike rule actions).
- **Fix:** Added `sensorIncrementScheduleCommand()` that builds the full path; swapped the call site in `BridgeAnimationEngine`.

#### 3. Composer cards not turning lights on after bridge upload
- Bridge upload succeeded (rules, sensor, schedule created), but the first rule only fires when the schedule next ticks (~3–18s away). Lights stayed dark after card tap.
- **Fix:** Added an **immediate prime frame** after `bridgeAnimationStore.save(manifest)` — renders step 0 of the composition and pushes it via `setGroupedLightEffect(on: true)` so the room lights up within ~1s of the tap.

#### 4. Dynamic composer cards (cascade/wave/breathe) frozen — REST scheduler suppressed
- `canRunOnBridge` was `true` for ALL non-mic presets, so every composition went through bridge upload.
- Bridge upload returned early without starting the REST scheduler.
- Bridge rule chains have a **3-second minimum step interval** (bridge firmware limit), making cascade/wave/breathe presets look completely frozen.
- **Fix:** Gated bridge upload on `preset.capabilityTier == .bridgeOptimized` only. Dynamic presets fall through to REST/Entertainment as before.

### Files changed
| File | Change |
|---|---|
| `HueHome/Core/Network/HueV1Client.swift` | Removed `autodelete` from schedule body; added `sensorIncrementScheduleCommand()` with full address |
| `HueHome/Core/Network/BridgeAnimationEngine.swift` | Swapped `sensorIncrementCommand` → `sensorIncrementScheduleCommand` for schedule |
| `HueHome/Core/Network/UnifiedOrchestrator.swift` | Added prime frame after bridge upload; gated bridge path on `.bridgeOptimized` tier |

### Architecture: bridge transport tiers
```
bridgeOptimized  (static motion + steady envelope)
  → Bridge upload automatically: lights persist after app close, prime frame turns on immediately

runtimeOnly  (any motion or non-steady envelope — cascade/wave/breathe/etc.)
  → REST/Entertainment: continuous 120ms updates, smooth animation
  → Bridge: NOT auto-uploaded (3s/step would freeze the effect)

hybrid  (mic-reactive)
  → REST/Entertainment only (bridge has no mic)
```

### What's working
- ✅ Schedule creates successfully (no more type 6 errors)
- ✅ `bridgeOptimized` presets upload, persist after app close, turn on immediately
- ✅ `runtimeOnly` compositions produce smooth continuous animation via REST

### What's next
- [ ] "Run on Bridge ⚡" explicit opt-in button in mixer tray for `runtimeOnly` presets
- [ ] Manual "Clean Bridge" button in Settings
- [ ] On-device soak test: bridgeOptimized preset, close app, verify lights keep cycling

---

## 2026-05-06 — Home Layout Rebuild + All Day Scenes (Cursor)

### What was built
- **Home rebuild (`DashboardView.swift`)** — Threw out the per-section ad-hoc padding model entirely and rebuilt Home with the canonical SwiftUI dashboard pattern. The visual design is **identical** — every section component (TimeSuggestionBanner, NextAutomationBanner, presetsBar, RoomCard, summaryHeader, zonesSectionHeader, nowPlayingBar) is unchanged. Only the wrapper layout was rewritten.
- **New body shape**:
  - Root: `ScrollView` (no ZStack, no GeometryReader, no custom layout profile).
  - Content: a single `VStack(alignment: .leading, spacing: 14)` containing every section in order.
  - Horizontal inset: `.padding(.horizontal, 20)` applied **once** at the ScrollView's content. Sections never set their own horizontal padding.
  - Background: `DashboardAmbientBackground.ignoresSafeArea()` lives on the `.background { ... }` modifier, not as a ZStack sibling. This decouples its safe-area behavior from content sizing.
  - Toast: `.overlay(alignment: .top)` for the orchestrator toast and `.overlay(alignment: .bottom)` for the preset toast.
  - Grid: `[GridItem(.adaptive(minimum: 170))]` — auto-balances to 1 column on iPhone SE (335pt content < 2*170+spacing) and 2+ columns on every larger device with no breakpoint logic. The `useWideCards` AppStorage flag forces 1-column when desired.
- **Presets row bleed** — `.padding(.horizontal, -20)` then `.padding(.leading, 20)` so the first chip aligns with the rail and the trailing chips scroll under the screen edge (Apple Music / App Store pattern).
- **Removed dead code** — `HomeLayoutProfile` struct, `homeLayout` computed property, `homeContentRail` wrapper, `roomScrollView`, `roomsGrid`, `zonesGrid`, the unused `sizeClass` and `dynamicTypeSize` environment reads, and the debug HUD in `MainTabView`.
- **All Day Scenes (Circadian Auto-Pilot)** — One-time location permission, local solar curve (sunrise/sunset), throttled grouped_light updates via `allDayRestSender`, persisted via `UserDefaults`. Settings UI in `AllDayScenesView` (toggle, set/refresh location, anchor summary).

### Functionality preserved (no regressions)
- ✅ Ambient time-of-day gradient background
- ✅ Greeting, on/off counter, status dot
- ✅ Time-aware suggestion banner with one-tap CTA
- ✅ Next-automation banner with countdown chip + multi-automation sheet
- ✅ Horizontal preset rail (Energize/Read/Relax/Sleep + favorited room scenes)
- ✅ Now-playing strip with multi-effect dropdown and "Stop"/"Stop All"
- ✅ Room cards: glow color, brightness slider, power toggle, ellipsis, scale animations, equatable diffing, SSE-driven optimistic state
- ✅ Collapsible Zones section, persisted via @AppStorage
- ✅ Pull-to-refresh, NavigationLink to RoomDetail, simultaneousGesture for SSE suppression
- ✅ Toast notifications, demo-mode title decoration
- ✅ Toolbar items (settings, power-all, layout toggle)
- ✅ Empty state and shimmer state

### What's working
- ✅ Linter clean (`DashboardView`, `MainTabView`).
- ✅ All Day Scenes feature compiles, persists state, and respects the latest-wins `RestSender` mailbox.

### What's left
- [x] User QA pass on iPhone SE (3rd gen) portrait completed via screenshot validation.
- [ ] User QA pass on iPhone mini / standard / Max + iPad (screenshot matrix).
- [ ] AI Scene Generation (next differentiator after Home QA).

### Gotchas
- `.adaptive(minimum:)` is the responsive grid contract — do not replace with custom screen-width math.
- The presets row bleed uses `.padding(.horizontal, -20)` followed by `.padding(.leading, 20)` — both modifiers are required; removing either breaks leading alignment or collapses the bleed.
- The ambient background MUST be applied via `.background { … }` modifier (not a ZStack sibling). A sibling with `.ignoresSafeArea()` propagates safe-area behavior to siblings via the ZStack's coordinate space, which is what caused the original SE clipping.
- Sections that produce intrinsic-width content (e.g. a plain `Text`) will leave whitespace on the right inside the leading-aligned VStack. Every section in `content` either uses HStack+Spacer or a LazyVGrid, both of which fill the proposed width.

### Current state
SE portrait validation is complete and looks correct. Home layout rebuild is stable; remaining step is cross-device matrix validation (13/14, Pro Max, iPad) before tagging a checkpoint.

---

## 2026-05-05 — Composer Engine Built (Antigravity/Gemini)

### What was built
- `CompositionModels.swift` — 4 layer configs (Palette, Motion, Envelope, Reaction) with full render math
- `CompositionEngine.swift` — Pure render engine, outputs CIE xy + brightness per light per frame
- `CompositionStore.swift` — JSON persistence + 20 built-in presets (5 ambient, 3 energetic, 12 holidays)
- `StudioViewModel.swift` — Added `.composition(presetID:)` strategy, `composerStudioCards`, apply/stop
- `UnifiedOrchestrator.swift` — Added `startCompositionMode()` with dual-transport (DTLS 25fps / REST 5fps)

### What's working
- ✅ All engine code compiles (BUILD SUCCEEDED)
- ✅ Existing Studio effects (Deck 1+2) unchanged and functional
- ✅ Multi-room concurrent effects still working
- ✅ 20 presets seed on first launch via JSON

### What's left (for next session)
- [ ] Phase 3A: Add Deck 3 to StudioView card carousel
- [ ] Phase 3B: Mixer tray layer tabs for compositions
- [ ] Phase 3C: Layer-specific slider controls
- [ ] Phase 3D: Save flow (name input → persist → new card)
- [ ] Phase 4: Polish (animations, haptics, seasonal banner)

### Gotchas
- `StudioStrategy` now requires `Equatable` conformance (added)
- `composerStudioCards` is a computed property, not a stored let (updates when store changes)
- Slider values write directly to `activeCompositionBox` — no debounce or API call needed
- The `sendColorParam` method searches `composerStudioCards` array too (line ~483)

### Current tag
`v0.17.0-cursor-ready`

---

## 2026-05-05 — Composer Phase 3A: Deck 3 UI (Cursor)

### What was built
- **`StudioView.swift`** — Third carousel page (Composer): category chips (`PresetCategory.allCases`), animated gradient-border **+ Create** hero, filtered preset grid with same `StudioCardView` as other decks, three deck dots, rename alert. Long-press context menu: Edit, Rename, Duplicate, Delete. In-season presets sort to the top; Holiday chip gets extra border emphasis when any preset `isInSeason`.
- **`StudioViewModel.swift`** — Hidden starter template preset (`composerStarterDraftPresetID`) excluded from grid; `applyStarterComposition()`, `ensureComposerStarterDraft()`, `studioCard(for:)`, `composerPresets(for:)`, `renameCompositionPreset`, `duplicateCompositionPreset`, `deleteCompositionPreset`; `sendParam` lookup includes starter card.

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED**

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet

### Gotchas
- Starter draft is persisted on first **+ Create** (not one of the 20 built-ins). Grid omits it by ID so it never appears as a card.
- `+ Create` title includes a leading “+” and a `plus.circle.fill` icon (slight redundancy).

### Current state
Phase 3A complete; ready for 3B.

---

## 2026-05-05 — Composer Routing + Queue Race Fixes (Cursor)

### What was built
- **`UnifiedOrchestrator.swift`** — Composer entertainment selection now matches room light refs to config lights (no blind `.first` config). Added Studio generation counter + `studioRestSender.clear()` on start/stop, and generation guards in Composer REST loop/enqueued closures to block stale delayed sends after stop/switch.
- **`SyncModeEngine.swift`** — `RestSender` gained `clear()` to drop pending mailbox work safely.
- **`StudioViewModel.swift`** — Added single-engine guard for `.appDriven`/`.composition` cards (stop other engine-based room effects before starting a new one). Added `apply(_:roomOverride:)` so the tapped room snapshot is used.
- **`StudioView.swift`** — Card taps now capture room snapshot and pass override into `apply`, removing selection race. Mixer header now shows explicit scope/transport badges (`ENT AREA`, `ROOM`, `COMPOSER: ...`).

### What's working
- ✅ `xcodebuild` generic iOS **BUILD SUCCEEDED** after each fix batch
- ✅ Room-target logs match user taps (`Hallway → Kitchen → Hallway → Main bedroom`)
- ✅ No delayed ghost re-activation observed after stop in retest

### What's left
- [ ] Phase 3B: Mixer layer tabs for compositions
- [ ] Phase 3C: Layer sliders
- [ ] Phase 3D: Save sheet
- [ ] Built-in preset UX: hide/unhide instead of delete

### Gotchas
- Studio engine in orchestrator is singleton (`activeStudioTask`); UI must enforce this to avoid conflicting room expectations.
- Room-selection race can occur if swipe/pick changes around tap time; using room snapshot at tap eliminates this.
- REST mailbox can still have one in-flight request; generation guards are required so stale closures no-op after stop.

### Current state
Composer room routing and delayed-send race appear stable in manual tests. Ready for Phase 3B implementation.

---

## 2026-05-05 — Composer REST backlog fix (Cursor)

### What was wrong
- `runCompositionREST` sent grouped_light PUTs every **200 ms (~5 Hz)**.
- `HueAPIClient` documents grouped_light at **~1 PUT/sec** — excess traffic queues on the bridge → **30–60 s lag** as stale commands drain.

### Fix
- Throttle Composer REST loop to **~1 Hz** (1.05 s spacing), dynamics ≈ **900 ms**. Logs/docs updated from “~5fps”.

### Current state
**BUILD SUCCEEDED**. Entertainment path unchanged (25 fps).

---

## 2026-05-05 — Composer Mixer UI (3B/3C) + Save (3D), Multi-room Notes (Cursor)

### What was built
- **`StudioView.swift`** — For `.composition` cards: mixer shows four layer tabs (Palette / Motion / Envelope / Reaction), tabbed controls bound directly to `vm.activeCompositionBox` (live sliders, pickers, toggles). Increased composer mixer tray height. Header save button (`square.and.arrow.down`) opens save sheet (name + SF Symbol grid).
- **`StudioViewModel.swift`** — `saveActiveComposition(name:icon:)` builds a `CompositionPreset` from `activeCompositionBox` and `compositionStore.save` (category `.myCreations`).

### Product / architecture notes (current behavior)
- **Multi-room:** Bridge-native effects (Deck 1) can still run in multiple rooms. **Composer and other `.appDriven` Studio engines are intentionally single-active globally** — applying in room B stops Composer/Live in room A (see earlier `StudioViewModel` guard). Matches one orchestrator Studio task + one Entertainment session per bridge.
- **Composer REST:** After grouped_light throttle fix, room-scoped REST Composer updates ~**1×/second**; smooth motion requires Entertainment path when config matches.

### What's left
- [ ] Phase 4 polish: tab cross-fade refinement, stronger haptics, seasonal banner, optional per-light REST path for smoother Composer without Entertainment

### Current state
Phase 3B–D composer mixer + save shipped in tree; verify on device with Entertainment vs REST badges.

---

<!-- NEXT SESSION: Append below this line -->

## 2026-05-06 — SE Portrait Layout Spike (Cursor)

### What was built
- Investigated compact-device clipping reports using iPhone SE (3rd gen) simulator screenshots across Home / Scenes / Studio.
- Ran multiple adaptive layout experiments on Home and tab-shell sizing (`DashboardView`, `MainTabView`, `HueHomeApp`) to test whether width clamping originated from section padding, grid strategy, or root container sizing.
- Reverted non-improving runtime layout experiments after validation so no unstable SE workaround remains in shipped UI code.
- Added roadmap context in `DEVDOC.md` for post-Composer differentiators (AI scene generation first, then sharing, weather-reactive, and Tier 2 items).

### What's working
- ✅ Build passes after cleanup (`xcodebuild` BUILD SUCCEEDED).
- ✅ Studio still renders cleanly on SE (useful baseline for Home refactor target).
- ✅ Existing Composer 3B/3C/3D + routing/queue fixes remain intact.

### What's left
- [ ] Refactor Home layout architecture to match Studio's deterministic container model.
- [ ] Introduce one Home content rail + breakpoint profile (compact/standard/large) instead of per-section ad-hoc sizing.
- [ ] Validate SE portrait first, then iPhone standard/Max and iPad, with screenshot matrix before release.

### Gotchas
- SE issue appears architectural (root/intrinsic width interactions across mixed sections), not a simple padding tweak.
- Landscape can look acceptable while compact portrait fails, so portrait-on-small-device must be the primary acceptance gate.

### Current state
SE portrait Home still needs a structural refactor; experimental quick fixes were rolled back. Next step is a focused Home layout-system pass while preserving current visual style.

---

## 2026-05-06 — AI Scene Generation Architecture Artifact + UX Decisions (Cursor)

### What was built
- Created a new canvas artifact at `canvases/ai-scene-gen-and-composer-revamp.canvas.tsx` describing:
  - AI Scene Generation architecture (`prompt -> provider -> validate -> CompositionPreset -> Composer engine -> lights`)
  - Provider strategy (FoundationModels-first, optional cloud fallback, local curated fallback)
  - Data contract constraints for generated `CompositionPreset` values
  - Progressive disclosure rules for Composer tools (essential vs advanced controls)
  - Visual flow mockups for top bar, AI generation states, and 2-axis hue control concept
- Iteratively rewrote the artifact to incorporate product decisions from live review feedback.

### Product/UX decisions captured
- Keep **room picker** as the primary navigation anchor in Studio (explicitly prioritized).
- Remove top deck-name labels if there is a conflict with room-picker clarity.
- Keep AI entry as a **pill**.
- Keep visible **AI badge** on generated cards.
- Default AI apply scope = **current room**.
- Regenerate flow clarified with simple UX framing (live regenerate + card-level regenerate).

### Follow-up decision (latest)
- User requested to **keep room picker exactly as-is** for now (no immediate room-picker redesign implementation).

### What's left
- [ ] Choose first implementation slice (recommended: AI pill shell + state handling, or HueRail prototype behind flag).
- [ ] Convert selected parts of artifact into concrete StudioView/StudioViewModel tickets.

### Current state
Architecture and UX artifact is complete and updated with current decisions. No production Studio code changes were applied in this session.

---

## 2026-05-06 — Documentation Refresh (Cursor)

### What was built
- Updated `CURSOR_KICKOFF.md` from a Composer build-instruction doc to a current-state kickoff.
- Reframed kickoff around what is already shipped vs what remains (polish, QA, transport/stability checks).
- Updated `COMPOSER_SPEC.md` with a top-level implementation status section and historical-plan clarifications.
- Corrected stale strategy references in `COMPOSER_SPEC.md` from `composition(preset:)` to `composition(presetID:)`.

### What's working
- ✅ Session onboarding docs now align with current implementation state.
- ✅ Future sessions can start from active priorities instead of already-completed phases.

### What's left
- [ ] Run cross-device screenshot QA matrix and record outcomes.
- [ ] Complete remaining Composer polish items (transitions, haptics, seasonal affordances).
- [ ] Begin first AI Scene Generation implementation slice once UI QA is green.

### Gotchas
- Large planning docs can quickly become stale after rapid implementation phases; add explicit status headers to prevent accidental rework.

### Current state
Documentation is now synchronized for current v0.17.x direction; no runtime code paths changed in this session.

---

## 2026-05-06 — DEVDOC Consistency Pass (Cursor)

### What was built
- Updated `DEVDOC.md` Composer section to include a 2026-05-06 status note clarifying it is mostly implemented and now serves as architecture reference.
- Corrected stale strategy notation in `DEVDOC.md` from `StudioStrategy.composition(preset:)` to `StudioStrategy.composition(presetID:)`.
- Updated the roadmap block in `DEVDOC.md` to mark Composer core as done and set `v0.17.x` focus to polish + QA + transport UX hardening.

### What's working
- ✅ `DEVDOC.md`, `CURSOR_KICKOFF.md`, and `COMPOSER_SPEC.md` now align on Composer status.

### What's left
- [ ] Cross-device screenshot matrix pass (Home + Studio Deck 3).
- [ ] Remaining Composer polish items and transport UX validation.

### Gotchas
- Historical design sections are still useful but need explicit status annotations to prevent duplicate implementation work.

### Current state
Primary documentation is synchronized with current implementation state; no production code changes in this pass.

---

## 2026-05-06 — Composer AI Pill + Prompt Generation v1 (Cursor)

### What was built
- Updated `StudioView.swift` Composer `+ Create` hero to support inline AI mode:
  - Added a small `wand.and.stars` affordance on the create pill.
  - Tapping AI expands the same pill into prompt input with `Generate` and `Cancel`.
  - Added inline loading state and error messaging beneath the hero.
- Added AI generation pipeline in `StudioViewModel.swift`:
  - Introduced a local-first `AICompositionGenerator` abstraction (`AICompositionDraft` + error type).
  - Added `generateCompositionFromPrompt(_:)` with input trimming, prompt-length validation, generation lock, and user-facing error/status messages.
  - Generated outputs map directly to valid `CompositionPreset` objects and save into `CompositionStore` as `.myCreations`.
- On successful generation, Studio now auto-applies the generated preset to the captured room snapshot and opens live mixer flow.

### What's working
- ✅ `xcodebuild` generic iOS build succeeds after changes.
- ✅ AI flow uses the same creation surface (no modal detour) and keeps one-tap Composer mental model intact.
- ✅ Guardrails in place for empty prompts, duplicate taps while generating, and recoverable generation failures.

### What's left
- [ ] Swap local heuristic generator to FoundationModels-backed provider behind the same abstraction.
- [ ] Add persisted AI badge metadata for generated presets (model field + migration-safe decode path).
- [ ] Tune prompt UX copy and optional suggested prompt chips.

### Gotchas
- Nested button interactions in the create hero can cause accidental trigger overlap; implementation avoids this by separating create and AI actions into explicit independent buttons.
- Generation is currently deterministic/local by design to keep UX stable while backend provider is integrated.

### Current state
AI entry is now integrated into Deck 3 creation pill and is production-safe for local generation. Foundation model provider wiring is the next implementation slice.

---

## 2026-05-06 — Composer Polish: Layer Activity + Seasonal Banner (Cursor)

### What was built
- Added Composer layer-activity metadata to `StudioCard` via new `compositionLayerActivity` payload.
- Implemented preset-derived layer activity detection in `StudioViewModel` to flag active/customized layers (`palette`, `motion`, `envelope`, `reaction`).
- Updated `StudioCardView` to render compact layer chips (`🎨 🌊 📈 🎤`) with active vs inactive styling for Composer cards.
- Added a lightweight seasonal banner in Deck 3 when seasonal presets are currently active.
- Refined composition tab content transition with a subtle fade+scale identity swap for cleaner layer switching feel.

### What's working
- ✅ Build succeeds after polish updates.
- ✅ Composer cards now show at-a-glance layer activity affordance.
- ✅ Seasonal context appears without changing existing deck flow.

### What's left
- [ ] FoundationModels provider integration behind current AI generator abstraction.
- [ ] Cross-device screenshot matrix validation for Home + Studio Deck 3.
- [ ] Final transport UX hardening checks for ENT vs REST labels/behavior.

### Gotchas
- Adding fields to `StudioCard` required updating every catalog card constructor to keep init sites compiling.

### Current state
Composer polish advanced with visual layer activity cues and seasonal deck affordance; compile status remains green.

---

## 2026-05-06 — AI Provider + Preset Metadata Migration (Cursor)

### What was built
- Updated `CompositionPreset` in `CompositionModels.swift` with migration-safe AI metadata:
  - Added optional `aiPrompt` and `providerModel`.
  - Implemented custom `init(from:)` to decode both fields with graceful `nil` fallback for legacy JSON.
  - Implemented explicit `encode(to:)` for forward-compatible persistence.
- Replaced local heuristic generation path in `StudioViewModel.swift` with FoundationModels-backed generation:
  - Added `LanguageModelSession` request path (guarded by `canImport(FoundationModels)` and availability).
  - Added JSON extraction + decode pipeline for structured model output.
  - Added validation clamp step for all returned numeric fields (palette/motion/envelope/reaction ranges).
- Added AI-card visual affordance in `StudioCardView` (inside `StudioView.swift`):
  - Shows compact `wand.and.stars` badge for AI-generated composition cards.
  - Badge sits alongside layer activity chips and remains compact-layout safe.

### What's working
- ✅ Generic iOS build succeeds after provider integration and metadata migration.
- ✅ Existing composition JSON remains readable due decoder fallback behavior.
- ✅ New AI-generated presets persist prompt/model metadata and show AI badge.

### What's left
- [ ] Cross-device QA snapshot pass (SE/mini/standard/Max/iPad) for badge/chip density.
- [ ] Optional: transition from text-JSON parsing to strict guided structured output (`@Generable`) for stronger model guarantees.

### Gotchas
- FoundationModels can be unavailable per-device/runtime; generator now fails gracefully with clear user-facing message.

### Current state
AI generation now uses FoundationModels with clamp validation, and preset metadata is migration-safe for older saved compositions.

---

## 2026-05-06 — Composer UX Stabilization + Gamut-Aware Color Pipeline (Cursor)

### What was built
- Hardened AI generation reliability in `StudioViewModel.swift`:
  - Added markdown-fence sanitization before JSON decoding.
  - Added detailed decode failure logging (raw JSON candidate + decode error details).
  - Added tolerant decode path for variant provider payloads (including missing palette fields / `colors` array fallback mapping).
  - Added local fallback draft generator when FoundationModels fails/unavailable (notably simulator/runtime generation failures).
- Replaced fragmented Palette controls with a unified 2D Hue/Saturation pad in `StudioView.swift`:
  - Removed separate hue slider, saturation slider, and color-dot row.
  - Added 2D drag pad with thumb, clamp-safe drag math, and compact-layout-safe sizing.
  - Added live thumb tracking while dragging to eliminate perceived input lag.
- Improved Composer mixer tray interactions/lifecycle:
  - Added tap-outside dismissal overlay.
  - Added swipe-down-to-dismiss for inline mixer with threshold/predicted-end handling.
  - Added header drag-indicator tap dismiss.
  - Added keyboard dismissal utility (`hideKeyboard()`) and applied it to relevant tap backgrounds.
  - Re-anchored tray as a bottom overlay to reduce lock/unlock geometry glitches.
- Fixed hue pad visual consistency:
  - Corrected saturation axis orientation.
  - Added selected-color thumb fill + color preview dot to better reflect selected values.
  - Lifted tray above tab bar to avoid lower-edge clipping on compact devices.
- Implemented gamut-aware color accuracy improvements (Step 1 + 2):
  - Added Hue gamut triangles (A/B/C) and `clampXYToGamut` in `HueColorUtils.swift`.
  - Added room-dominant gamut resolution in `StudioViewModel` and `UnifiedOrchestrator`.
  - Clamped Composer color output to resolved gamut in both Entertainment and REST render paths.
  - Refactored hue pad to canonical clamp-first flow so displayed thumb/readout track post-clamp output (not pre-clamp gesture values).
- Tuned REST fallback responsiveness during color scrubbing:
  - Added interaction-aware cadence in `runCompositionREST`:
    - drag: faster interval + shorter transition
    - idle: conservative interval + smoother transition
  - Added post-drag settle write for cleaner final color landing.

### What's working
- ✅ AI generation succeeds more consistently across phone + simulator with graceful fallback path.
- ✅ 2D hue pad interaction is smoother (live tracking, clamp-safe drag, consistent thumb/readout).
- ✅ Mixer dismissal is easier and more native-feeling (tap-outside, swipe-down, header tap).
- ✅ Composer color output is now gamut-clamped end-to-end, reducing unreachable-color mismatch.
- ✅ Build and lint checks passed after each major slice.

### What's left
- [ ] Optional follow-up: switch Composer pad to full xy-native editing surface for even tighter perceptual parity.
- [ ] Optional follow-up: tune drag REST profile further (e.g., 0.7s/140ms) based on bridge/device QA.
- [ ] Product decision pending: enforce portrait-only orientation to avoid landscape UI regressions.

### Gotchas
- Hue bridge grouped_light path remains rate-limited; REST fallback will never feel as fluid as Entertainment streaming.
- Mixed-gamut rooms still require compromise mapping; dominant-gamut strategy is a practical middle ground.

### Current state
Composer UX is significantly more stable and color handling is now gamut-aware from picker input through transport output, with improved simulator resilience for AI generation.

---

## 2026-05-06 — Composer Multi-Room Runtime + Scheduler Tuning (Cursor)

### What was built
- Implemented non-destructive mixer dismissal in `StudioView.swift`:
  - Dismiss gestures (tap outside / swipe down / header tap) now collapse controls instead of stopping the running composition.
  - Added `Live Controls` quick chip to reopen the mixer while effect continues.
- Enabled multi-room concurrent compositions:
  - Refactored Composer orchestration from single global task semantics to room-scoped runtime state in `UnifiedOrchestrator`.
  - Updated `StudioViewModel` apply/stop logic so composition no longer force-stops other composition rooms.
- Replaced per-room composition REST loops with a global fair scheduler:
  - Added round-robin scheduler over active composition rooms to prevent one room from monopolizing bridge updates.
  - Added room-scoped start/stop generation guards and lifecycle cleanup.
- Added debug telemetry for Composer scheduler:
  - Per-room effective send rate (`hz`), average lag (`avgLagMs`), max lag (`maxLagMs`) logged in DEBUG builds.
- Improved startup responsiveness and pacing:
  - Added immediate prime write when a composition starts so newly selected rooms visibly turn on immediately.
  - Reduced smoothing/transition durations for faster visual response.
  - Passed pre-resolved gamut from `StudioViewModel` into `startCompositionMode` to avoid redundant fetch overhead at start.

### What's working
- ✅ Composition cards can now run concurrently across multiple rooms (REST path).
- ✅ Mixer can be hidden/reopened without canceling live composition playback.
- ✅ Scheduler fairness improved vs independent per-room loops.
- ✅ New composition start feels more immediate due to prime write.
- ✅ Build and lint checks passed after each slice.

### What's left
- [ ] Final scheduler calibration from fresh telemetry after latest transition/tick tuning.
- [ ] Decide whether to introduce "Bridge Optimized" vs "Custom Live Engine" mode badges.
- [ ] Optional: portrait-only lock decision if landscape regression costs remain high.

### Gotchas
- Native Hue dynamic effects remain smoother because they execute in bridge firmware; Composer remains app-driven for custom behavior.
- Multi-room Composer on grouped_light is bounded by bridge rate limits; scheduling can optimize fairness but not fully bypass hardware limits.

### Current state
Composer now supports practical multi-room concurrency with fair scheduling, faster start behavior, and a cleaner non-destructive mixer UX, while preserving custom composition flexibility.

---

## 2026-05-06 — Composer Responsiveness Investigation + Final Tuning Pass (Cursor)

### What was built
- Ran iterative tuning on Composer runtime behavior with repeated full build verification.
- Added and used DEBUG scheduler telemetry (`hz`, `avgLagMs`, `maxLagMs`) to validate runtime pacing and fairness.
- Tuned composition transition durations and startup behavior:
  - Shorter live transitions for Composer REST writes.
  - Immediate prime write on composition start so newly activated rooms visibly respond right away.
- Optimized startup path:
  - Reused `StudioViewModel`-resolved gamut by passing a `gamutOverride` into `startCompositionMode(...)` to avoid redundant fetches during room activation.
- Refined scheduler pacing strategy:
  - Maintained round-robin fairness and interaction-aware behavior.
  - Reduced burst-like write behavior in follow-up tuning attempts.

### What was verified
- ✅ Full iOS build succeeds after all tuning passes.
- ✅ Multi-room composition concurrency remains functional.
- ✅ Startup responsiveness improved via prime write.
- ✅ Native dynamic effects remain noticeably smoother than Composer under equivalent conditions.

### Findings from logs/telemetry
- Composer can show low scheduler lag (`avgLagMs` near 0) while still feeling visually laggy.
- This indicates the main bottleneck is not app-side queue backlog, but grouped_light REST animation granularity/cadence limits vs bridge-native dynamic effects.
- Native dynamic effects feel smoother because they execute in bridge firmware after one-shot effect commands.
- Composer (custom 4-layer runtime) still requires continuous grouped_light updates in REST mode, which has a lower smoothness ceiling.

### What's left
- [ ] Decide/implement Bridge-optimized composition identifiers and tiers (bridgeOptimized/hybrid/runtimeOnly) for each preset.
- [ ] Add clear user-facing capability badge so saveability/smoothness expectations are explicit.
- [ ] Evaluate transport strategy for best smoothness:
  - prioritized active-room cadence,
  - adaptive per-room degradation,
  - optional bridge-optimized compile path where possible.

### Current state
Composer is materially improved and instrumented, but logs confirm that REST grouped_light remains the limiting factor for “native-like” smoothness; next milestone is capability-tiering and bridge-optimized pathways.

---

## 2026-05-06 — Composition Optimization Tier Metadata + UI Badge (Cursor)

### What was built
- Added composition optimization identifiers directly to preset metadata in `CompositionModels.swift`:
  - `optimizationTier: bridgeOptimized | hybrid | runtimeOnly`
  - `bridgeOptimizationFlags: [BridgeOptimizationFlag]`
  - `bridgeOptimizationReason` computed string for UI/debug visibility.
- Implemented migration-safe decoding for existing saved presets:
  - if new fields are missing, flags are inferred from layer configs and tier is auto-derived.
- Added tier/reason propagation into Studio cards in `StudioViewModel.swift`:
  - `StudioCard` now carries `compositionOptimizationTier` + `bridgeOptimizationReason` for Composer presets.
- Added compact Composer card badge UI in `StudioView.swift`:
  - Tier capsule (`Bridge Optimized`, `Hybrid`, `Runtime Only`)
  - concise reason hint sourced from optimization flags.

### What’s working
- ✅ Every composition preset now stores optimization metadata on the model.
- ✅ Existing stored JSON presets remain compatible via decode-time inference.
- ✅ Composer cards show a compact optimization tier badge.
- ✅ Reason flags are visible in a compact, user-facing hint line.

### What’s left
- [ ] Optional: tune inference heuristics per preset family if product wants stricter tier semantics.
- [ ] Optional: surface full reason list in detail UI (e.g., context menu/details sheet) instead of compact hint truncation.

### Gotchas
- Existing presets in user storage did not contain new keys, so migration-safe defaults were required to avoid breaking decode.
- Tiering here is intentionally deterministic and model-based (layer config analysis), not runtime transport performance telemetry.

### Current state
Composer presets now have persisted bridge optimization identifiers and reason flags, and Studio displays a compact badge for immediate user clarity about bridge optimization capability level.

---

## 2026-05-06 — Composer Transport Hardening (Cursor)

### What was built
- Hardened Composer transport/scheduler behavior in `UnifiedOrchestrator`:
  - Added per-room due-time pacing using `nextDueAt` (instead of high-frequency global sleep clamp).
  - Set steady-state target to ~1Hz per room for grouped_light REST sends.
  - Added bounded interaction burst mode (short faster window) with automatic decay.
  - Added optional Entertainment-first path in `startCompositionMode(..., preferEntertainment:)` with REST fallback.
- Improved overlap safety in `StudioViewModel`:
  - Apply path now resolves room light IDs for composition/app-driven cards too.
  - Overlap detection now prevents competing effects across overlapping room/zone scopes beyond bridge-native-only cases.
- Added panic-stop affordance in `StudioView`:
  - New `stop.circle.fill` toolbar action appears while anything is running and calls `vm.stopAll()`.

### What’s working
- ✅ Full iOS build succeeds after transport hardening.
- ✅ Composer REST cadence is now significantly less burst-prone and closer to bridge limits.
- ✅ Quick slider interaction gets temporary responsiveness boost, then auto-returns to stable pacing.
- ✅ Overlapping room/zone runs are reduced by broader overlap checks.
- ✅ One-tap panic stop now available at top nav while effects are active.

### What’s left
- [ ] On-device validation pass for Entertainment-first composition route with multiple bridge layouts.
- [ ] Tune burst window/interval based on real bridge telemetry in live household scenarios.
- [ ] Optional: add explicit UI transport indicator per running composition room (REST vs Entertainment).

### Gotchas
- Entertainment API remains bridge-wide/single-session; composer entertainment preference must still gracefully fall back when unavailable.
- REST grouped_light smoothness remains bounded by bridge behavior even with improved scheduler pacing.

### Current state
Composer now uses a safer pacing model, broader overlap protection, bounded burst behavior, and optional entertainment-preferred transport, with a global panic-stop control for runaway room effects.

---

## 2026-05-06 — Composer Tier Guardrails + Runtime Hint (Cursor)

### What was built
- Added strict per-tier Composer REST cadence guardrails in `UnifiedOrchestrator`:
  - `CompositionRuntime` now tracks `tier`.
  - Scheduler enforces minimum interval by tier via `minIntervalForCompositionTier(_)`.
  - Current policy: `bridgeOptimized`, `hybrid`, and `runtimeOnly` all clamp to **>= 1.0s** per room/zone when on REST.
- Added debug clamp diagnostics:
  - When interaction burst requests faster updates than allowed, DEBUG builds log `[Composer][Guardrail] clamped cadence ...` with requested vs allowed interval.
- Wired tier into orchestrator start path:
  - `StudioViewModel` now passes `tier` into `startCompositionMode(..., tier:)` so cadence policy is centrally enforced.
- Added runtime-only expectation cue in mixer UI (`StudioView`):
  - For composition cards running on REST with `runtimeOnly` tier, mixer shows: `Runtime-only REST is rate-capped`.

### What’s working
- ✅ Full iOS build succeeds after guardrail/hint changes.
- ✅ REST cadence now respects the explicit 1.0s policy regardless of temporary burst requests.
- ✅ Users now get a visible smoothness expectation hint during runtime-only REST playback.

### What’s left
- [ ] Optional: expose active effective cadence value (e.g., `1.00s`) in mixer for QA visibility.
- [ ] Optional: differentiate future tier policy (e.g., slower bridgeOptimized cadence if needed).

### Gotchas
- The clamp is intentionally conservative and will trade responsiveness for reliability on grouped_light REST.
- Entertainment path remains preferred for high-motion smoothness; REST guardrails reduce lag/fighting but cannot match DTLS fluidity.

### Current state
Composer now has a centralized tier-aware REST safety policy, debug observability for cadence clamping, and a user-facing runtime-only rate-limit hint, improving predictability and reducing bridge overload behavior.

---

## 2026-05-06 — Composer Transport Choice + QA Cadence Visibility + AI Prompt Chips (Cursor)

### What was built
- Added explicit Composer transport choice UX in `StudioView`:
  - For non-bridgeOptimized composition cards, applying now prompts:
    - `Room Only (REST)`
    - `Entertainment Area (Streaming)`
    - `Always Room Only`
    - `Always Entertainment Area`
  - Persisted preference and prompt behavior are stored via `UserDefaults`.
- Added transport preference model in `StudioViewModel`:
  - `CompositionTransportPreference` enum (`auto`, `roomOnly`, `entertainmentArea`)
  - `compositionTransportPreference` + `isCompositionTransportPromptEnabled`
  - apply path now supports `preferEntertainmentOverride` and routes preference into `startCompositionMode(...)`.
- Added real-time REST cadence exposure in `UnifiedOrchestrator`:
  - `activeRESTCadence: Double?`
  - `activeRESTCadenceByRoom: [String: Double]`
  - cadence UI updates throttled (~1.5s) to avoid observation churn.
- Wired cadence into Studio UI:
  - Runtime-only mixer hint now appends live cadence when available, e.g.:
    - `Runtime-only REST is rate-capped (Live: ~1.0s)`.
- Added AI suggested prompt chips for Composer generation in expanded AI panel:
  - `Static Warm Sunset`
  - `Cozy Reading Corner`
  - `Energetic Club Pulse`
  - `Blinking Christmas Lights`
  - Tapping a chip fills prompt and immediately triggers generate+apply flow.

### What’s working
- ✅ Full iOS build succeeds after all changes.
- ✅ Composer transport is now user-selectable with optional persisted default.
- ✅ Runtime-only REST cadence is visible in mixer for QA.
- ✅ AI chip affordance works and triggers generation quickly.

### What’s left
- [ ] Optional: add a lightweight reset action for transport preference in settings/studio overflow.
- [ ] Optional: show active transport scope tag directly on card before apply (not only in mixer).

### Gotchas
- Entertainment remains bridge-wide/single-session; selection still depends on config/session availability and may fall back to REST.
- Runtime-only compositions on REST are intentionally capped for bridge safety; cadence visibility clarifies this but cannot make REST as smooth as DTLS.

### Current state
Composer now has explicit user-controlled transport scope, observable REST cadence for QA validation, and stronger AI prompt affordances to steer generation quality while preserving bridge-safe scheduling constraints.

---

## 2026-05-06 — Field QA Observation: Composer Start Order Contention (Cursor)

### What was observed
- In live testing, effect stacking behavior depends on apply order:
  - If Composer card is applied **last**, multi-effect behavior appears smooth and stable.
  - If Composer card is applied **first**, later effects feel laggy / delayed.
- User hypothesis (likely correct): Composer path is still competing for transport/state ownership when started first.

### Evidence pattern
- Symptoms look like transport contention rather than bridge rejection:
  - Composer telemetry still reports near-target cadence (~1 Hz REST in tested cases).
  - Other effects degrade primarily when Composer owns early lifecycle.
- This points to orchestration/order arbitration rather than pure rate limit failure.

### Likely root-cause area (next debugging slice)
- Cross-mode coordination between Composer runtime and subsequent effect engines:
  - ownership handoff sequencing,
  - overlap arbitration timing,
  - shared resource/session release timing (REST/Entertainment),
  - residual grouped_light transition/state settling from Composer startup.

### What to do next
- Add explicit “mode ownership handoff” instrumentation:
  - log per-room owner transitions (Composer ↔ bridgeNative/appDriven),
  - log overlap-stop decisions with timestamps,
  - log transport/session active state before/after each apply.
- Reproduce with deterministic sequence tests:
  1) Composer first → native/appDriven cards
  2) native/appDriven first → Composer
  3) same sequence with/without entertainment selection.
- If confirmed, add a small guarded handoff delay or hard ownership barrier when transitioning away from Composer-first starts.

### Current state
- Transport controls, cadence guardrails, and UI diagnostics are materially improved.
- A reproducible sequencing edge case remains: **Composer-first startup can still degrade subsequent effect smoothness**.

---

## 2026-05-06 — Composer Handoff Barrier + Sequencing Instrumentation (Cursor)

### What was built
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added `[Handoff]` lifecycle logs in `stopCompositionMode(roomID:)` for:
    - stop requested,
    - `studioRestSender.clear()` moment,
    - post-clear settle complete,
    - teardown complete.
  - Added `try await Task.sleep(for: .milliseconds(150))` immediately after `studioRestSender.clear()` in `stopCompositionMode(roomID:)`.
  - Added matching `[Handoff]` lifecycle logs in `stopStudioMode()` and a 150ms settle delay right after `studioRestSender.clear()`.
- `HueHome/UI/Studio/StudioViewModel.swift`
  - In overlap arbitration inside `apply(_:roomOverride:preferEntertainmentOverride:)`, added `[Handoff]` logs around `await stopEffect(on:)` to make the barrier observable.
  - Added explicit `[Handoff]` startup log right before new effect startup sequence begins.
  - In `stopEffect(on:)` bridge-native cleanup path, added:
    - `[Handoff]` log before per-light `no_effect`,
    - 150ms settle delay after batched `no_effect`,
    - `[Handoff]` completion log after settle.

### What’s working
- ✅ Hard async barrier already present in overlap flow remains intact (`await stopEffect(on:)`).
- ✅ New startup is now instrumented to begin only after overlap cleanup + settle barrier.
- ✅ Teardown paths now include explicit bridge settle windows after REST sender clear / `no_effect` cleanup.
- ✅ Project builds successfully with:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Run on-device/simulator sequencing QA and confirm `[Handoff]` logs appear in strict order during rapid override scenarios.
- [ ] Validate no perceptible regression in perceived responsiveness when quickly swapping cards (150ms barrier tradeoff).

### Gotchas
- `xcodebuild` in sandbox failed due to host permission/simulator service constraints; non-sandbox build succeeded.
- Handoff delay is intentionally short (150ms) to avoid bridge queue flooding while minimizing UX lag.
- Entertainment remains bridge-wide and single-session; sequencing barriers do not change that hardware constraint.

### What to test
- 1) **Composer -> Native immediate override**
  - Select room A, start a Composer card, immediately tap a bridge-native card.
  - Expect `[Handoff]` teardown logs to complete before startup log appears.
- 2) **Composer -> appDriven immediate override**
  - Start Composer, immediately tap Strobe/Party/Thunderstorm.
  - Expect same strict ordering and no interleaved startup before teardown completion.
- 3) **Overlap path (Home zone vs room)**
  - Run effect in room A, switch to Home zone and start another card.
  - Expect overlap detection log, awaited stop barrier, then startup barrier-clear log.
- 4) **Rapid repeated taps**
  - Repeatedly switch between two cards in same room.
  - Confirm no stuck effect state and no bridge command flood behavior.
- 5) **Cross-room non-overlap sanity**
  - Run room A effect, then room B effect with no shared lights.
  - Confirm independent behavior remains unchanged.

### Current state
Composer handoff now has explicit teardown instrumentation and guarded settle barriers at ownership boundaries. Build is green; remaining work is runtime QA to verify strict log ordering and user-perceived smoothness under rapid card switching.

---

## 2026-05-06 — Portrait Lock + Studio SE Mixer Fit + Title Picker Cleanup (Cursor)

### What was built
- `HueHome/Info.plist`
  - Locked app orientation to portrait by reducing `UISupportedInterfaceOrientations` to:
    - `UIInterfaceOrientationPortrait`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Added AppDelegate runtime orientation lock:
    - `application(_:supportedInterfaceOrientationsFor:) -> .portrait`
- `HueHome/UI/Studio/StudioView.swift`
  - Kept the original rolodex room/zone title interaction (swipe L/R rooms, U/D zones, tap for search sheet).
  - Removed the room/zone chevron icon from the Studio title row.
  - Added accessibility traits/hint so the title still reads as tappable control for the room/zone sheet.
  - Reworked mixer sizing for compact devices:
    - wrapped root in `GeometryReader`
    - dynamic tray cap based on available viewport (`resolvedMixerHeight(proxy:)`)
    - tab-bar/home-indicator aware bottom clearance
  - Reworked mixer scroll behavior:
    - composition controls now use a fill-height scroll region (`GeometryReader` + `ScrollView`)
    - essential parameter controls use same pattern
    - prevents bottom content from being clipped on iPhone SE-sized screens.

### What’s working
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Studio title remains tappable for room/zone search without visual chevron clutter.
- ✅ Mixer can grow taller on compact devices and keeps content scrollable to reach bottom controls.
- ✅ Orientation is portrait-only at plist and runtime delegate levels.

### What’s left
- [ ] Validate on real iPhone SE that all composition controls (including lower controls) are reachable without clipping.
- [ ] Verify no unexpected layout regressions on larger phones after dynamic tray cap changes.

### Gotchas
- Portrait lock is now enforced in two places (plist + AppDelegate delegate callback) intentionally for consistency.
- Mixer tray now consumes more vertical space on compact devices; this is deliberate to preserve control visibility.

### What to test
- 1) **Portrait lock**
  - Launch app and rotate device/simulator to landscape.
  - Expect UI to remain portrait with no layout rotation.
- 2) **Studio title row interaction**
  - In Studio, tap the room/zone title (no chevron now).
  - Expect Room/Zone search sheet to open exactly as before.
- 3) **Rolodex navigation still intact**
  - Swipe title left/right to cycle rooms; up/down to cycle zones.
  - Confirm transitions remain smooth and selection updates correctly.
- 4) **iPhone SE mixer fit (critical)**
  - On Composer card, open mixer and scroll through controls.
  - Confirm bottom controls are reachable and not hidden behind tab bar/home indicator.
- 5) **Non-composer mixer fit**
  - Use bridge-native and app-driven cards with several sliders.
  - Confirm lower rows remain reachable via scroll on compact height.
- 6) **Regression sanity**
  - Verify card grid remains visible when mixer is expanded/collapsed.
  - Verify stop/save buttons remain visible and tappable.

### Current state
App is now portrait-locked and Studio mixer layout is hardened for compact screens (including SE) with viewport-aware tray sizing and scrollable content regions. Next step is focused SE device QA for final visual tuning.

---

## 2026-05-06 — App Store Orientation Compliance + Runtime Rotation Toggle (Cursor)

### What was built
- `HueHome/Info.plist`
  - Restored full iPhone orientation set required for App Store upload validation:
    - `UIInterfaceOrientationPortrait`
    - `UIInterfaceOrientationPortraitUpsideDown`
    - `UIInterfaceOrientationLandscapeLeft`
    - `UIInterfaceOrientationLandscapeRight`
- `HueHome/Core/Services/AutomationHandler.swift`
  - Updated `AppDelegate.application(_:supportedInterfaceOrientationsFor:)` to be user-preference-driven:
    - default behavior remains portrait-only,
    - optional landscape via user setting.
  - Added `OrientationPrefs.allowLandscape` (`"app.allowLandscapeRotation"`) UserDefaults key.
- `HueHome/UI/Settings/SettingsView.swift`
  - Added new `APP` section toggle:
    - `Allow Landscape Rotation`
    - Backed by `@AppStorage("app.allowLandscapeRotation")`
    - Default is `false` (portrait lock remains default behavior).

### What’s working
- ✅ Upload-blocking orientation metadata issue is addressed by plist orientation restoration.
- ✅ Runtime behavior still defaults to portrait lock for normal users.
- ✅ Landscape can be explicitly enabled by testers/power users from Settings.
- ✅ Build succeeds:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What’s left
- [ ] Verify App Store upload path no longer returns error 90474.
- [ ] Validate that toggling landscape in Settings updates runtime behavior as expected across major app screens.

### Gotchas
- App Store validation checks declared plist orientations, not only runtime locks.
- Runtime orientation changes can appear delayed until next screen transition in some UIKit/SwiftUI stacks.

### What to test
- 1) **Upload compliance**
  - Archive + upload; confirm no orientation validation error (90474).
- 2) **Default lock behavior**
  - Fresh install / default settings: rotate device.
  - Expect portrait lock.
- 3) **Landscape opt-in**
  - Settings -> App -> enable `Allow Landscape Rotation`.
  - Rotate on Studio/Home/Settings; expect landscape support.
- 4) **Toggle off regression**
  - Disable toggle and retest rotation.
  - Expect portrait lock restored.

### Current state
Orientation handling is now split correctly between App Store compliance (full plist support) and product UX preference (portrait-first runtime lock with optional tester override). Build is green; next checkpoint is successful archive upload and quick on-device rotation QA.

---

## 2026-05-06 — Composer Mic + REST Snappiness + Tab Lazy-Load + Perf (Cursor)

### What was built

**Composer microphone (reaction layer)**  
- New `HueHome/UI/Studio/CompositionMicCapture.swift` — FFT band splits aligned with `VisualizerEngine`, lock-protected levels, `syncDemand(_:)` lifecycle.  
- `UnifiedOrchestrator` wires `CompositionMicCapture.reactionAudioLevel(for:)` into all `CompositionEngine.render` paths (REST scheduler, ENT loop, prime frame); `refreshCompositionMicDemand()` tied to composition lifecycle; weak `compositionEntertainmentParamBox` for mic-demand when ENT transport is active.  
- `HueHome/HueHomeApp.swift` — `Notification.Name` extensions: `composerMicExclusiveBegan`, `compositionMicPermissionDenied`.  
- `SyncModeEngine` observes `composerMicExclusiveBegan` and calls `stop()` if Sync is running (avoid dual `AVAudioEngine`).  
- `CompositionEngine` — **tap tempo** uses envelope BPM sine wave (no mic); mic sources still use passed `audioLevel`.  
- Exclusive handoff delay after posting mic notification: **35ms** (was 60ms).  
- **Parallel warmup**: When gamut must be fetched and reaction uses mic, mic `syncDemand(true)` runs **concurrently** with `resolveCompositionGamut` / `resolveDominantGamut`, and mic completion is **awaited before** blocking on gamut result (`StudioViewModel` + `UnifiedOrchestrator`).  
- ENT path: `tryStartEntertainment` and `findEntertainmentConfig` run **in parallel** when choosing streaming transport.

**REST Composer cadence (Sync-aligned)**  
- Scheduler uses **`0.15s × active composition room count`** as baseline (matches `SyncModeEngine` REST visualizer spacing model).  
- Separate **burst floors** for color-pad interaction vs idle tier guardrails (`bridgeOptimized` remains more conservative).  
- Idle/settle transition durations tightened slightly for grouped_light; post-send scheduler yield **40ms → 20ms**.

**Shell performance**  
- `MainTabView` — **lazy tab realization** (`realizedTabs`): Scenes / Studio / More roots not constructed until first visit; tab bar inserts current tab on tap; `onAppear`/`onChange` register selection for restoration.  
- `StudioView` — removed `.animation(..., value: currentDeck)` on deck `TabView` to reduce paging hitch.

### Files touched (high level)
- `CompositionMicCapture.swift` (new), `UnifiedOrchestrator.swift`, `CompositionEngine.swift`, `HueHomeApp.swift`, `SyncModeEngine.swift`, `StudioViewModel.swift`, `StudioView.swift`, `MainTabView.swift`, `HueHome.xcodeproj/project.pbxproj`

### What’s working
- ✅ `xcodebuild` HueHome scheme — BUILD SUCCEEDED (`generic/platform=iOS`)

### Gotchas
- Hue does not stream “voice” over the bridge — mic only improves **client-derived** levels fed into Composer; bridge latency unchanged.  
- `grouped_light` REST remains throughput-sensitive; burst paths must not defeat tier guardrails on weak bridges.  
- Lazy tabs: first open of Studio still pays full `StudioView` cost once.

### What to test (QA checklist)

**A — Composer mic**  
1. **Permission** — Fresh install or revoke mic: apply a composition with reaction source **Mic** (amplitude / bass / mid / treble). Expect system prompt once; if denied, capture still fails gracefully (optional toast pipeline not wired — verify no crash).  
2. **Reaction vs tap tempo** — Preset with **Tap tempo**: lights should pulse to **envelope BPM**, not room noise. Switch to **Mic amplitude**: verify motion follows voice/claps.  
3. **Sync exclusivity** — Start **Music Sync** (or any Sync mode using mic), then start **Composer** with mic reaction. Expect Sync to stop and Composer mic to work (no stuck dual-engine state).  
4. **ENT vs REST Composer + mic** — Same mic preset: room with entertainment area (streaming) and force **Room only (REST)** via transport prompt; verify both paths show reactive brightness (REST will be lower cadence).  
5. **Background** — Composer + mic running: send app to background; verify capture stops / no runaway session (resume foreground).

**B — REST Composer snappiness**  
6. **Single room** — Runtime composition on **one** room: updates should feel closer to **Sync visualizer** pacing (~150ms scale), not 1 Hz slideshow.  
7. **Multi-room** — Two+ rooms with compositions: verify fair rotation and **no** bridge lag storm (no 30–60s drain — back off if observed).  
8. **Interaction burst** — Drag color pad / interact: expect snappier bursts than idle (within reason).  
9. **bridgeOptimized tier** — Still more conservative cadence; confirm acceptable on real bridge.

**C — Startup / Studio shell**  
10. **Cold launch** — From quit: land on **Home**; first tap **Studio** — should avoid building Studio until then (may feel faster than when all tabs eager-loaded).  
11. **Deck paging** — Swipe Effects → Live → Composer; confirm no extra animation jank on deck switch.  
12. **iPad** — Sidebar tab switch still realizes tabs and shows content.

**D — Regressions**  
13. Apply **bridge-native** cards (candle, fire, …) — unchanged path.  
14. **Stop composition / handoff** — Stop Composer then apply another Studio card; no stuck lights or duplicate sessions.

### Current state
Composer reactions can use real microphone levels with Sync-safe exclusivity; REST Composer pacing matches the app’s Sync REST model for dynamic tiers; main shell defers heavy tabs until first visit. Ready for **device QA** (mic + multi-room + bridge load).

---

## 2026-05-06 — Studio Room Target Race + Composer REST Efficiency Pass (Cursor)

### Problem observed
- Composer apply could target the wrong room under rapid UI interaction.
- Logs showed mismatches like `selectedRoom: Main bedroom` while `groupedLightID` resolved to Bathroom.
- Composer REST mode still generated heavy traffic (frequent `PUT /grouped_light/...`) and startup duplicated `GET /light` work.

### What was fixed

**1) Room-targeting race in Studio UI**
- `HueHome/UI/Studio/StudioView.swift`
  - Removed render-time `roomSnapshot` captures from card/grid/menu paths.
  - Room is now captured at action time inside apply helpers, so apply always uses current selection.
  - Updated helper signatures:
    - `applyCardWithTransportPrompt(_:)`
    - `applyCompositionQuick(_:mode:)`
    - `composerPresetOverflowActions(preset:card:)`

**2) Startup GET dedupe in apply flow**
- `HueHome/UI/Studio/StudioViewModel.swift`
  - Added cached-light overloads:
    - `resolveLightIDs(for:api:cachedLights:)`
    - `resolveDominantGamut(for:api:cachedLights:)`
  - Apply now fetches bridge light inventory once (only when needed for device-backed rooms) and reuses it for:
    - overlap detection / room light resolution
    - dominant gamut resolution
  - Eliminates redundant back-to-back `GET /light` calls at composition startup.

**3) Balanced scheduler efficiency tightening**
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Added extra balanced-profile skip gate for tiny deltas sent too recently.
  - Increased balanced idle / low-power intervals for `.hybrid` and `.runtimeOnly` tiers.
  - Goal: preserve interaction responsiveness while reducing sustained REST chatter in non-interacting periods.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) **Room correctness under fast interaction**
  - Rapidly change room/zone and immediately tap composer cards / overflow actions.
  - Confirm `selectedRoom` and `groupedLightID` always map to the same target room.
- 2) **Composer startup traffic**
  - Start a composition and confirm reduced duplicate `GET /light` bursts.
- 3) **REST efficiency in Balanced**
  - Let a composition run idle for 30-60s; expect fewer PUTs than prior runs.
  - During active slider/pad interaction, responsiveness should remain acceptable.

### Current state
Wrong-room apply race is closed at the Studio action layer, startup light fetches are deduplicated, and Balanced REST cadence is more conservative when visual deltas are small. Ready for on-device validation focused on room-target integrity and perceived smoothness vs call volume.

---

## 2026-05-06 — Composer Color Edit Immediate Flush (REST burst override)

### Problem observed
- In Composer REST mode, user hue/saturation pad edits could be treated as "not meaningful" by balanced low-power gating, causing delayed/no visible color response immediately after drag.
- Logs showed low-power skips right after pad interaction (`Δxy` near zero after gamut clamp), even though user expected instant feedback.

### What was built

**User-edit forced burst path**
- `HueHome/UI/Studio/CompositionEngine.swift`
  - `CompositionParamBox` now includes:
    - `forceRESTBurstUntil: TimeInterval`
    - `triggerRESTBurst(seconds: 0.55)`
  - Purpose: mark a short post-edit window where REST scheduler should prioritize sending.

- `HueHome/UI/Studio/StudioView.swift`
  - Hue/saturation pad now calls `triggerRESTBurst()`:
    - on drag change
    - on drag end
  - Keeps existing `isColorPadInteracting` semantics.

- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Scheduler reads `userEditBurstActive = runtime.paramBox.forceRESTBurstUntil > now`.
  - During this window:
    - bypass low-power + efficiency skip gates
    - use burst cadence/floor path (same responsiveness class as interaction burst)

### Why this works
- Even if gamut clamp results in tiny `Δxy`, a direct UI edit now forces near-term sends so the bridge gets an immediate state update.
- Balanced mode remains efficient outside the short user-edit burst window.

### Verification
- ✅ Lints clean on edited files.
- ✅ Build succeeded:
  - `xcodebuild -project HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`

### What to test
- 1) Start Composer in Bathroom (REST transport).
- 2) Drag hue/saturation pad briefly and release.
- 3) Confirm visible color response occurs immediately after drag (no perceived dead period).
- 4) Let composition idle for 20-30s; verify cadence still backs off in balanced mode.

---

## 2026-05-06 — Composer Color Pad Haptics + Ultra-Low REST Cadence Constants (Cursor)

### What was built
- `HueHome/UI/Studio/StudioView.swift`
  - Added continuous, throttled haptic feedback while dragging the Composer hue/saturation pad:
    - New state: `lastHuePadHapticAt`
    - During `DragGesture.onChanged`, fires `HapticManager.shared.selection()` at most once every ~80ms.
    - Resets haptic timer on drag end; existing end-of-drag haptic remains.
- `HueHome/Core/Network/UnifiedOrchestrator.swift`
  - Aggressively lowered Composer REST scheduler interval constants for fast-response testing:
    - Lowered idle baseline (`preferredComposerIdleInterval`) and all tier minimums.
    - Lowered non-burst floors (`minimumComposerRESTInterval`) and burst floors (`minimumComposerBurstFloor`).
    - Tightened burst interval calculation (`max(0.03, syncRestInterval * 0.25)`).
    - Lowered low-power idle intervals to keep cadence high even during small-delta periods.

### What's working
- ✅ Lints clean on edited files (`StudioView.swift`, `UnifiedOrchestrator.swift`).
- ✅ Build succeeded:
  - `xcodebuild -project /Users/brianbean/Desktop/huehome-pro-v0.3.0/HueHome.xcodeproj -scheme HueHome -destination 'generic/platform=iOS' build`
- ✅ Composer color pad now provides tactile feedback during drag (not only on drag end).

### What's left
- [ ] On-device bridge QA for overload/lag behavior with the new ultra-low intervals (single room + multi-room).
- [ ] Confirm no command-flood side effects (dropped updates, delayed bridge recovery, or perceived jitter).
- [ ] Decide final production cadence policy after telemetry review (`hz`, `avgLagMs`, `maxLagMs`).

### Gotchas
- REST grouped_light still has practical bridge throughput limits; very low interval constants can reduce stability even if app-side scheduler lag remains near zero.
- Haptic feedback is intentionally throttled to avoid excessive vibration spam during continuous drags.

### Current state
Composer editor responsiveness is now aggressively biased toward immediacy: the color pad gives live haptic pulses during drag, and REST cadence guardrails are significantly lowered for stress/perf validation. Build is green; next step is focused real-bridge QA before locking production values.

---

## 2026-05-07 — Bridge-Stored Animation Engine: Root Cause + Fix (Antigravity/Gemini)

### Problem
Compositions applied from Studio did not persist when the app was closed. The bridge-stored v1 animation chain (rules + CLIP sensor + schedule) was failing silently at rule creation with error 608/6.

### Root cause (after 4 iterations of debugging)
**v1 rule/schedule action addresses must be relative paths** — NOT the full `/api/{token}/...` path.

```diff
# WRONG (what we were sending):
- "address": "/api/ZVcY.../lights/1/state"

# CORRECT (what the bridge expects):
+ "address": "/lights/1/state"
```

The bridge internally resolves the user context for rule/schedule actions. Including the token made the address malformed, causing:
- Error 608: "Rule actions contain errors or an action on an unsupported resource"
- Error 6: "parameter, transitiontime/on/address/method, not available" (bridge couldn't parse the action at all)

Additional bugs found and fixed during the debugging process:
1. **v1/v2 light ID mismatch** — v2 uses UUIDs, v1 uses numeric IDs ("1", "2"). Added `resolveV1LightIDs()`.
2. **Double rule creation** — Code created rules twice (scene-only, then deleted and recreated with sensor advance). Collapsed to single-pass.
3. **Scene activation in rules** — v1 rules don't reliably support `{"scene": "id"}` on group actions. Switched to direct per-light state commands (`PUT /lights/{id}/state`).
4. **Sensor kickoff** — Sensor started at 0; setting to 0 didn't trigger the `dx` condition. Now starts at 99.
5. **Orphaned resources** — Multiple test runs left 18+ scenes and 3+ sensors on the bridge. Added `purgeAllChromaGlowResources()` and auto-cleanup before upload.

### What was built
- **`HueV1Client.swift`** — v1 REST client for rules, scenes, CLIP sensors, schedules, resourcelinks. Includes `resolveV1LightIDs()`, fetch methods for all resource types, and `token` exposed for rule action construction.
- **`BridgeAnimationEngine.swift`** — Pre-renders compositions into v1 rule chains. Direct per-light state commands (no scene activation). Sensor-based step counter with schedule-driven cycling. `purgeAllChromaGlowResources()` for cleanup.
- **`UnifiedOrchestrator.swift`** — Bridge-stored upload integration with auto-cleanup, `isBridgeStored` state flag, transport priority: Bridge-Stored > Entertainment > Per-light REST > Grouped REST.

### Two implementation paths identified

**Option A: Fix v1 relative paths (3-line fix)** — Change addresses in `sceneActivationCommand()`, `sensorIncrementCommand()`, and direct light actions from `/api/{token}/...` to `/...`. Gets the full v1 rule chain working for ALL composition patterns.

**Option B: v2 Dynamic Scene** — Create v2 scene with `POST /clip/v2/resource/scene`, recall with `{"recall": {"action": "dynamic_palette", "duration": 5000}}`. Bridge autonomously cycles colors. Zero rules/sensors/schedules. Already have `CreateSceneRequest`, `activateScene(id:speed:)`, and `HueScene.isDynamic` in the codebase.

**Decision: Implement both.** Option A for complex motion (cascade/wave/scatter), Option B as fast-path for simple palette presets.

### What's left
- [ ] Fix v1 relative paths (Option A — 3 lines)
- [ ] Implement v2 dynamic scene fast-path (Option B)
- [ ] Add manual "Clean Bridge" button in Settings
- [ ] On-device soak test: apply animation, close app, verify lights keep going
- [ ] Resource capacity monitoring (rules/sensors/schedules are finite on bridge)

### Gotchas
- v1 rule actions: addresses are RELATIVE (`/lights/1/state`), NOT full API paths
- v1 rules: max 8 actions per rule. With N lights + 1 sensor bump = N+1 actions. Safe for up to 7 lights per room.
- v2 dynamic scenes: less control over per-light timing (bridge controls cycle), but zero resource overhead
- Bridge has finite resource limits (~100 rules, ~250 sensors, ~100 schedules). Must clean up between runs.
- `purgeAllChromaGlowResources()` finds all CG_ prefixed resources and deletes them. Currently runs before every upload.

### Current state
Root cause identified and documented. Build is green. Two implementation paths approved. Next step: apply the 3-line v1 fix, test on device, then build v2 dynamic scene path.

---

## 2026-05-08 — Multi-Bridge Routing Foundation for Widget/Watch (Cursor)

### What was built
- **`HueHome/Core/Network/WidgetDataStore.swift`** — Extended shared snapshot contract with `bridgeID` on `WidgetRoomSnapshot`, added `WidgetBridgeCredentials`, added bridge map persistence (`hue_widget_bridges_v1`), and added `credentials(for:)` resolver with legacy fallback.
- **`HueHome/Core/Network/UnifiedOrchestrator.swift`** — Writes bridge-aware room/zone snapshots, publishes active bridge credential map for App Group consumers, and pushes bridge map through watch sync path.
- **`HueHome/HueHomeApp.swift`** — Updated `WatchSessionManager.push` payload to include `wc_bridges_v1` (plus legacy fallback keys).
- **`HueHomeWidget/WidgetIntents.swift`** — Switched interactive widget intents to resolve per-room bridge credentials instead of global single-bridge creds.
- **`HueHome/Intents/HueRoomEntity.swift` + `HueHome/Intents/HueIntents.swift`** — Added `bridgeID` to intent entities and routed Siri intents through per-bridge credential resolution.
- **`LightShadeWatchApp Watch App/WatchStore.swift` + `LightShadeWatch/WatchWidgetStore.swift`** — Added bridge map decoding/storage and per-room bridge credential resolution on watch/watch-widget paths.

### What's working
- ✅ iOS app target (`HueHome`) compiles successfully after multi-bridge routing changes.
- ✅ watchOS app target (`LightShadeWatchApp Watch App`) compiles successfully after watch sync/store updates.
- ✅ Widget/intent/watch code paths now have a deterministic per-room bridge routing key (`bridgeID`) and a shared bridge credential map.
- ✅ Legacy single-bridge keys are still emitted/read as fallback for backward compatibility.

### What's left
- [ ] Add interactive watch complication/widget toggle intent wiring in `LightShadeWatch` (UI currently non-interactive).
- [ ] Validate on physical watch that Bridge 2 toggles now route correctly under real-world stale-cache conditions.
- [ ] Add explicit failure surfacing/telemetry when room routing metadata is missing or stale.
- [ ] Optionally add groupedLightID→bridgeID fallback map for extra resilience if room bridge metadata is absent.

### Gotchas
- Existing watch/widget data can remain stale across sessions; routing fixes require fresh app-driven sync to repopulate bridge-aware payloads.
- Some watchers still rely on legacy `hue_widget_bridge_ip`/`hue_widget_token`; keeping fallback keys avoids hard breaks while migrating.
- Multi-bridge correctness depends on `bridgeID` being present in snapshots; missing IDs will fall back to legacy credentials.

### Current state
Multi-bridge routing foundation is implemented across iOS widget, Siri intent, watch sync, and watch stores. Both iOS and watch targets build cleanly. Next step is on-device verification for Bridge 2 behavior and then watch widget interactivity wiring.
