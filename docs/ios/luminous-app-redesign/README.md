# ChromaGlow — the Luminous app (one product, one language)

Branch `experiment/luminous-app-redesign` (from `experiment/composer-2-v2.2-ui-ux` @ `dcb3df4`, build 59).
Rollback tag: `checkpoint/pre-luminous-app-redesign`. Experiment — never merged without Brian's say-so.

## The idea

> **The app is a dark room, and the only light in it is the light you control.**

Composer 2 already lives by that sentence: a void-black stage, your lamps drawn as glowing orbs that pool light on
the floor, a background that glows in the colours of what's playing, glass panels, rounded heavy names, and one big
button that sends light out. Every other screen was built in an older language (flat grey cards, amber on
everything, monospaced caps, icon-only toolbars). This branch makes the whole app speak the Composer's language,
and reorganises the app around the three things people actually do with their lights.

## Why it is organised this way

People do three things with a lighting app, at very different frequencies:

| Job | How often | Where it lives | The one gesture |
|---|---|---|---|
| **Control** — on/off, dim, a mood | many times a day | **Home** | tap a room's power, drag its glow |
| **Set a still mood** — "Movie Night", "Dinner" | daily | **Scenes** (and each room's Scenes) | tap a scene |
| **Bring a room alive** — storms, fire, Halloween, parties, your own | occasionally, for delight | **Composer** | try a look → Go Live |
| Set up & maintain — bridges, people, automations | rarely | **More** | — |

So the tab bar is exactly those four: **Home · Scenes · Composer · More**. The frequency order is the left-to-right
order. Nothing creative competes with control on Home; nothing administrative competes with creation in the
Composer.

### What changed in the structure, and why

- **Studio → Composer.** Composer 2 was reachable only through one card on the third deck of Studio. It is the
  showpiece, so it becomes a tab. The tab's root is the **Composer library** (a living catalogue: every card plays its
  look), and opening a look presents the full **Composer** instrument (Looks · Tune · Layers, the luminous stage, Go
  Live) exactly as it exists today. Library → instrument mirrors Home → Room: an overview you browse, then a stage
  you play.
- **Studio becomes Studio Classic — kept, not deleted.** Studio still uniquely owns things that would break if it
  disappeared: Siri's "start a look/effect", QR scene import and share, bulb firmware effects (Candle, Fire,
  Sparkle…), the Live engines, Perform, the older Composer v1 looks, the Entertainment Area chooser, and the stop and
  recovery hooks for effects it started. It stays mounted exactly as before (hidden from the tab bar) and is one tap
  away at the bottom of the Composer library ("More tools"). Siri and QR links still land in it. This keeps the
  experiment honest: the main flow is the new product; nothing anyone relies on regresses. **End state** (follow-up
  work, not this branch): bulb effects move into each room's Looks, Perform and the AI composer move into the
  Composer, v1 looks are imported once, Siri gains a Composer entity, and Studio Classic is deleted.
- **One stage, everywhere.** The Composer's stage painter now draws *real* lamp state as well as looks. A room card on
  Home, a room's hero, and a look in the Composer are all the same picture, so you learn it once: an orb is a lamp;
  its colour and glow are what the lamp is doing.
- **Colour belongs to light.** UI chrome is neutral glass. The only saturated colour on screen comes from light:
  your lamps' current colours (Home, Room), a scene's palette (Scenes), a look's frames (Composer). Each screen's
  background ambience is tinted by exactly that.

## Principles (the rules every screen follows)

1. **Dark room.** Background is `LuminousAmbience` over the void, tinted by the light that screen is about.
   Never a flat colour, never light mode.
2. **Glass, not grey.** Every container is `.luminousGlass()` (or `.luminousPanel(glow:)` when it stands for a lit
   thing). No `GlassmorphicCard`, `StageCard`, `HuePalette.Noir.surface` boxes in redesigned screens.
3. **One action colour.** The signal gradient (cyan → violet) marks the thing that sends light out — Go Live,
   Activate, Apply, the selected tab, the selected segment. Live/on-now is green. Amber means edited/attention.
   Red only destroys. Amber is no longer the brand accent.
4. **Names are rounded and heavy; sentences are plain.** `LuminousType.display` for a screen's name (with an eyebrow
   line above and one sentence below — the Composer's title block), `.title` for sections, `.cardTitle` for cards.
   No monospaced uppercase "stage tags" in redesigned screens; use `LuminousEyebrow` sparingly.
5. **Headers are round glass.** Tab roots draw their own header (no navigation bar): state chip / capsule picker on
   the left, round glass buttons on the right — the Composer's header. Pushed screens keep the system back button
   (edge swipe) over a transparent bar (`.luminousNavigationChrome()`), with the title in the content.
6. **Everything answers the finger and the eye.** Springy presses (`LuminousPressStyle`), haptics on every commit,
   ≥ 44 pt targets, VoiceOver labels and values, Reduce Motion stops all drifting, and every clock pauses with
   `\.isTabActive` and in the background.
7. **Honest words.** No protocol jargon, no promises the hardware can't keep (the existing copy rules and guards
   still apply — see "Contracts").

## The flow

```
Launch ─▶ (unpaired) Welcome: pair a bridge or Explore Demo
       └▶ (paired)   Home
Home ─── room card ─▶ Room (stage · Lights | Scenes | Looks) ─── lamp ─▶ Light
     ─── Now Playing ─▶ Composer (the live look)
Scenes ─ scene card ─▶ activates (long-press: favourite, speed, rename, copy/move, delete)
Composer (library) ─ look ─▶ Composer instrument (Looks · Tune · Layers, Go Live)
                   ─ More tools ─▶ Studio Classic
More ─▶ Automations · Devices · Entertainment Areas · Physical Controls · People · Bridges · Settings · Tour
```

**The live thread.** When a look is live anywhere, Home shows it first (a Now Playing card with its own little
stage and Stop), the room's stage frame turns green, and its card in the Composer library says Playing. You can
always stop it from where you are.

## Screens

### Home
Header: state chip ("4 of 7 rooms on"), round All-off button. Title block: eyebrow = time-of-day
("Good evening" with sun/moon symbol), display = "Your home", subtitle = "N lights · M rooms on" (+ "Demo home").
Then, in order: guest banner · Now Playing card(s) · suggestion (all off) · next automation · **Moods** (Energize,
Read, Relax, Sleep as glowing mood tiles, then starred scenes) · music strip (when a session runs) · **Rooms** grid ·
**Zones** (collapsible). Ambience = the colours the lamps are showing.

**Room card** = a mini stage (each lamp an orb in its real colour and brightness, off lamps as dark glass) + name +
"5 lights · 78 %" + a power button that glows in the room's colour + (when on) a glow slider painted with the room's
colours. Long-press → colour wash sheet. Tap → Room.

### Room
Hero stage (the Composer's painter on real state, tap a lamp to open it) · title block (archetype, name, "4 of 5 on")
· power + brightness glow slider · segmented **Lights · Scenes · Looks**:
- **Lights** — My Colors strip (paint mode), the lamps as glass tiles (orb, name, %, power), select mode.
- **Scenes** — room-scoped moods (Energize…Sleep), the room's scenes, new scene, schedules for this room.
- **Looks** — Composer looks to play here (Play here / Open in Composer).

### Light
A single big orb (the lamp's colour, its glow = its brightness) · colour wheel + swatches + My Colors · warmth ·
brightness · Identify.

### Scenes
Title block ("Scenes", "17 scenes · 4 on now") · search · filter chips (All · Favourites · each room) · On now ·
Favourites · per-room sections of scene cards (an arc of orbs in the scene's palette, name, room, dynamic badge,
active glow) · Studio scenes shelf. Long-press keeps every existing action.

### Composer (tab root)
Header: room capsule (the room looks play in) + connection chip. Title block ("Composer", "Light that feels alive")
· hero: what's playing (or a showpiece) on the room's stage, Open/Stop · music source strip · the library (For you ·
categories · Yours; every card plays) · Build your own · More tools → Studio Classic. Opening a look presents the
existing Composer instrument unchanged.

### More
Title block ("More", connection chip) · glass groups: Control (Automations, Devices, Entertainment Areas, Physical
Controls) · People (Profiles & Access, Share Invite) · System (Bridges, Connection) · App (identity + **Signify
disclaimer**, Settings, Replay the Tour, **Song Tempo Data → getsongbpm.com**, Demo Mode). Secondary screens use the
same groups and rows.

## Contracts that the redesign must keep (non-exhaustive — see AGENTS.md)
- Load-bearing behaviour lives in view models and the orchestrator; redesigned views call the **same** functions.
  Home: `setRoom`, `setBrightness`, `applyAutomationPreset`, `activateGlobalScene`, `turnAllOff`,
  `requestNowPlayingStop(entry)`, `signalNavigationStarted()`, the 120 s stale-refresh, pull-to-refresh order.
  Room: the `.task` seed/SSE contract (fresh-cache skip, one SSE subscriber held for the view's life,
  `onColorCommitted`, `onScenesChanged`), paint mode is sticky and excludes select mode, guest gates.
- `\.isTabActive` pauses every always-on clock. Sliders keep local drag state and commit once.
- The orchestrator toast renders only in MainTabView.
- Legal: Signify disclaimer in More **and** Settings; GetSongBPM backlink in More; Demo reachable on first launch;
  photosensitivity notice (now also shown the first time the Composer tab opens).
- Guards: no `REST` substring in UI string literals; the G6 banned-terms list; `Composer2Lab`/`Composer2Document`/
  `Composer2LiveOutput` names only in the allow-listed files (new Composer-tab code uses `Composer2PlaybackCenter`,
  `Composer2ThemeCatalog`, `Composer2Store`, `Composer2View`, `Composer2MiniStage` only); tour copy rules
  (`TutorialCatalogTests`).
- StudioView/StudioViewModel/UnifiedOrchestrator are not modified.

## Kit reference — `HueHome/UI/Components/LuminousKit.swift`
| Need | Use |
|---|---|
| Screen background | `LuminousAmbience(colors:)` in a `ZStack` behind a `ScrollView` |
| Card / group | `.luminousGlass()`; lit by a colour: `.luminousPanel(glow:glowStrength:)` |
| Stage container | `.luminousStageFrame(isLive:)` |
| Screen name | `LuminousScreenTitle(title:eyebrow:eyebrowSymbol:eyebrowTint:subtitle:)` |
| Section | `LuminousSectionHeader(title:subtitle:symbol:) { trailing }`, `LuminousEyebrow` |
| Header buttons | `LuminousRoundButton`, `LuminousRoundGlyph` (Menu label), `LuminousCapsuleLabel`, `LuminousStateChip` |
| Choices | `LuminousChip`, `LuminousSegmented` |
| Levels | `LuminousGlowSlider` (commit on `onEditingChanged(false)`) |
| Actions | `LuminousPrimaryButton` (signal / live), `LuminousSecondaryButton`, `LuminousPowerButton` |
| Lists | `LuminousGroup { LuminousRow … LuminousRowDivider() … }` |
| States | `LuminousLiveBadge`, `LuminousFactBadge`, `LuminousNotice`, `LuminousEmptyState` |
| Real light | `LuminousLight.color(of:)`, `.palette(of:)`, `.frames(for:)`; stages in `LuminousStage.swift` |
