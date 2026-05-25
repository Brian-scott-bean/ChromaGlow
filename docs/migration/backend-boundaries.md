# Backend Boundaries

## Backend Philosophy

The backend supports ChromaGlow. It does not replace the Hue Bridge or become the required path for normal lighting control.

The app is local-first.

## Backend May Own

- Feature flags.
- Release cohorts.
- Crash and health telemetry.
- Non-sensitive app configuration.
- Optional user identity.
- Optional non-sensitive preset metadata sync.
- Support diagnostics.
- Short-lived pairing handoff tokens.
- Schema/version contracts shared by iOS and Android.

## Backend Must Not Own

- Raw Hue bridge credentials.
- Normal on/off light commands.
- High-frequency entertainment streaming.
- Local bridge discovery.
- Microphone/audio processing.
- Required runtime path for controlling lights on the LAN.
- Long-lived secrets for physical Hue bridges.

## Pairing Handoff Concept

Later, the already-paired iOS app may generate a short-lived handoff payload for Android.

The handoff should:

- Expire quickly.
- Avoid centralizing permanent Hue credentials.
- Require the Android device to verify the local bridge directly.
- Be optional, not required for normal pairing.
- Be logged only with non-sensitive metadata.

## Telemetry Principles

Collect enough to operate the product, not enough to spy on users.

Useful events:

- App startup success/failure.
- Bridge discovery success/failure.
- NUPnP fallback usage.
- Pairing success/failure.
- Local network permission denial.
- Certificate trust failure.
- SSE disconnect/reconnect.
- Scene activation success/failure.
- Entertainment session start failure.
- Widget action success/failure later.

Avoid:

- Room names by default.
- Light names by default.
- Raw local IP addresses unless explicitly needed and privacy-reviewed.
- Bridge credentials.
- Audio data.
