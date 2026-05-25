# MDR 0001: Native Android Plan, No Flutter

## Status

Accepted.

## Decision

ChromaGlow / HueHome Pro will move forward with a native Android migration plan.

We will not use Flutter for the app migration.

The target architecture is:

- Native iOS app: Swift / SwiftUI / SwiftData / Apple platform targets.
- Native Android app: Kotlin / Jetpack Compose / Room / OkHttp / Android platform APIs.
- Minimal backend: feature flags, telemetry, non-sensitive coordination, optional pairing handoff.
- Possible future shared logic: Kotlin Multiplatform only after native Android boundaries are proven.

## Why

The app's hardest problems are not generic UI problems. They are platform, local-network, and hardware-adjacent problems:

- Philips Hue bridge discovery over local network.
- Self-signed bridge certificate trust handling.
- Local HTTPS communication with Hue Bridge.
- DTLS / UDP entertainment streaming.
- Multi-bridge coordination.
- Microphone / audio sync constraints.
- Widgets, watch/wearable features, and platform-specific background execution rules.
- Secure local credential storage.

A cross-platform UI framework would still require large native integration layers for the most important parts of the product. Native Android keeps Android-specific problems in Android code and lets the app use platform APIs directly.

## Consequences

### Positive

- Cleaner mental model for a small team.
- Better long-term Android quality ceiling.
- Less risk of debugging across Dart/native/plugin layers.
- Android can avoid known iOS architectural debt rather than copy it.
- KMP remains available later for pure shared logic.

### Tradeoffs

- iOS and Android screens will be implemented separately.
- Feature parity must be managed deliberately through contracts and documentation.
- Shared UI velocity is lower than Flutter.
- The team must maintain two native mobile skillsets.

## Explicit Non-Goals

- Do not build a Flutter module.
- Do not attempt a single shared UI codebase.
- Do not route normal Hue control through the backend.
- Do not centralize Hue bridge credentials.
- Do not start with DTLS, Studio, widgets, or Wear OS before basic Android parity is working.

## Revisit Criteria

This decision can be revisited only if one of the following becomes true:

- The product direction changes away from direct local Hue control.
- The team adds experienced Flutter/native-plugin developers.
- Android parity is deprioritized in favor of a simpler cross-platform companion app.
- A future KMP/shared-logic extraction proves that significantly more logic is portable than expected.
