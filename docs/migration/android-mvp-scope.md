# Android MVP Scope

## Product Goal

The Android MVP should be a releasable app, not just a technical proof of concept.

## MVP Must Include

- Native Android app shell.
- Demo mode.
- Bridge discovery.
- Bridge pairing.
- Secure local credential storage.
- Dashboard.
- Room/light control.
- Scenes list.
- Scene activation.
- Basic settings.
- Basic error/loading states.
- Basic telemetry hooks or local telemetry interface.
- Internal testing distribution.

## MVP Should Not Include

- Studio/composer full parity.
- DTLS entertainment streaming.
- Microphone sync.
- Widgets.
- Wear OS.
- Marketplace.
- User accounts.
- Web.
- Google Home.
- KMP/shared logic extraction.

## Why Scenes Are Included

Dallin considers scenes part of a releasable MVP. The app is rich enough that dashboard-only would feel too incomplete.

## Demo Mode

Demo mode should be included early because it supports:

- Product review.
- Screenshots.
- App store/demo walkthroughs.
- Development without a physical Hue setup.
- Safer UI testing.

## Parity Definition

Android MVP parity does not mean every feature exists.

It means the first Android build can support the core user promise:

> A user can install the app, connect to their Hue Bridge, see their lighting setup, control lights/rooms, and activate scenes.

## Post-MVP Parity Order

1. Broader UI parity.
2. Automations.
3. Widgets and Wear OS.
4. Studio/composer.
5. DTLS entertainment / mic sync.
6. Marketplace scene sharing.
7. Web / Google Home / other integrations.
