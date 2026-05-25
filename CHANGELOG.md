# ChromaGlow — Changelog

All notable changes are documented here.
Format: `[vX.Y.Z] — YYYY-MM-DD`
Types: `Added` | `Changed` | `Fixed` | `Removed` | `Architecture`

---

## [v0.1.0] — 2026-04-13
### Added
- Bridge mDNS auto-discovery + HTTPS pairing (CLIP API v2)
- Keychain credential storage
- Glassmorphic dashboard with real-time SSE updates
- Room on/off toggle + grouped brightness control
- Light control: brightness + color temperature per bulb
- Scene viewer (horizontal strip per room)
- Scene creator (capture current state → POST to Bridge)
- Scene deletion (long-press context menu)
- Automations viewer + enable/disable toggle
- Settings screen (bridge info, sign-out)
- Custom app icon (glowing lightbulb)

### Added (Widgets)
- Home screen: Small (rooms-on count), Medium (4-room grid), Large (full list)
- Lock screen: Circular (gauge), Rectangular (room list), Inline (text)
- Customizable widget: room pinning via AppIntent / WidgetConfigurationIntent
- Focused Small + Focused Medium layouts for pinned room
- Interactive tile system foundation (AppIntentTimelineProvider)

### Architecture
- CLIP API v2 REST client (URLSession + self-signed cert bypass)
- SSE event streaming (HueSSEService)
- App Group shared UserDefaults (WidgetDataStore)
- Widget extension targeting iOS 17+

---

## [Unreleased — Stage 1] — In Progress
### Architecture (Planned)
- Navigation redesign: TabView + NavigationStack per tab, NavigationSplitView on iPad
- iOS 17 minimum for main app target
- SwiftData model layer (replaces UserDefaults for metadata/log)
- Complete CLIP v2 API client (all 26+ resource types)
- @Observable migration (replaces ObservableObject / @Published)
- Design token system (typed colors, spacing, radius, shadows)
- Full component library (GlassCard, PillButton, BrightnessSlider, etc.)
- Adaptive layout (AdaptiveGrid, ResponsiveCard, InspectorPanel)
- Full SSE event coverage (add/delete/error + all resource types)
- Custom glassmorphic tab bar (reorderable)
- StoreKit 2 (one-time Pro unlock)
- Privacy manifest (PrivacyInfo.xcprivacy)
- Demo / preview mode (App Review compliance)
