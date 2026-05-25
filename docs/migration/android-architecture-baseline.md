# Android Architecture Baseline

## Goal

Build a native Android app that reaches platform parity with the existing ChromaGlow iOS app over time without copying the iOS monolith.

## Baseline Stack

- Language: Kotlin
- UI: Jetpack Compose
- Local database: Room
- Preferences: DataStore
- Secure storage: Android Keystore
- HTTP: OkHttp
- Async/state: Coroutines and Flow
- Local discovery: Android NsdManager plus NUPnP fallback
- Dependency injection: Hilt or Koin, to be decided
- Build system: Gradle

## Architecture Shape

Use clear layers:

```text
ui/
  compose screens
  view models
  UI state models

domain/
  entities
  use cases
  repository interfaces
  pure decision logic

data/
  repository implementations
  Room DAOs/entities
  DataStore preferences
  Hue API clients
  discovery implementation
  secure credential access

platform/
  Android permissions
  network discovery adapters
  foreground services
  widgets
  Wear OS integrations later
```

## First Android Milestone

The first Android milestone is daily-use parity, not full product parity.

Build in this order:

1. App skeleton builds locally.
2. Bridge discovery scaffold.
3. Bridge pairing.
4. Secure bridge credential persistence.
5. Fetch rooms, zones, lights, and scenes.
6. Dashboard render.
7. Room/light toggle.
8. Scene activation.
9. Basic error and loading states.
10. Internal test build.

## Explicitly Later

Do not start with:

- Studio/composer parity.
- DTLS entertainment streaming.
- Microphone sync.
- Android widgets.
- Wear OS.
- Backend account sync.
- KMP extraction.

## Android-Specific Rules

- Never store raw bridge credentials in plaintext preferences.
- Do not use a trust-all TLS manager.
- Treat local network permission denial as an expected app state.
- Treat microphone/background execution limits as product requirements, not bugs.
- Prefer Kotlin data classes for state equality unless there is a strong reason not to.
- Avoid one giant orchestrator; use repositories and use cases.
