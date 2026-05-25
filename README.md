# HueHome Pro

**The definitive Philips Hue lighting OS for iPhone, iPad, Mac, and Apple Watch.**

> Built on Hue CLIP API v2 · iOS 17+ · SwiftUI · WidgetKit · AppIntents

---

## What It Is

HueHome Pro replaces every other Hue app with a feature-rich, premium experience:

- **Full light control** — color, temperature, brightness, gradients, per-bulb detail
- **Effect Engine** — 10 composable engines, 70+ effects (heartbeat, breathing, Aurora, music sync, and more)
- **Complete automation builder** — IF/THEN routines, geofencing, circadian planner, Focus integration
- **Interactive widgets** — fully customizable tile system on home screen, lock screen, and StandBy
- **Device management** — sensors, buttons, battery, firmware, Zigbee health
- **Cross-platform** — iPhone, iPad, Mac, Apple Watch

---

## Build Status

| Stage | Theme | Status |
|---|---|---|
| 1 | Architectural Foundation | 🔄 In Progress |
| 2 | Complete Light Control + Effect Engine | ⏳ Planned |
| 3 | Devices & Sensors | ⏳ Planned |
| 4 | Automation Builder + Geofencing | ⏳ Planned |
| 5 | Widget Ecosystem (Interactive) | ⏳ Planned |
| 6 | Entertainment Mode | ⏳ Planned |
| 7 | Intelligence & Social | ⏳ Planned |
| 8 | Platform Expansion | ⏳ Planned |

---

## Requirements

- iOS 17+ (iPhone / iPad)
- macOS 14+ (Mac — Stage 8)
- watchOS 10+ (Apple Watch — Stage 8)
- Philips Hue Bridge (v2 square bridge)
- Local network only — no cloud required

---

## Privacy

- **No cloud servers** — communicates directly with your Hue Bridge on local network
- **No analytics** — zero telemetry, zero tracking
- **No account required** — Bridge credentials stored in iOS Keychain only
- Microphone: Music Sync only (never recorded or stored)
- Location: Geofencing automations only (never sent anywhere)
- Health data: Apple Watch HR Sync only (never stored)

---

## Migration (Android / multi-developer)

Cross-platform migration planning, Milestone 0 task packets, and architecture decisions live in [`docs/migration/`](docs/migration/README.md).

---

## Disclaimer

HueHome Pro is an independent third-party application. Not affiliated with, endorsed by, or connected to Signify or Philips Hue.
