# Backend Options Brief

ChromaGlow is local-first. The backend should support the product without becoming the control path for Hue lights.

## Backend Responsibilities

Good backend responsibilities:

- Feature flags.
- Crash/health telemetry.
- Release cohorts.
- Optional user identity.
- Optional non-sensitive scene/preset marketplace metadata.
- Support diagnostics.
- Short-lived pairing handoff tokens.

Bad backend responsibilities:

- Raw Hue bridge credentials.
- Required local light control.
- High-frequency entertainment streaming.
- Microphone/audio processing.
- Required local bridge discovery.

## Option A: Firebase / Google Cloud

### What it is

Firebase is Google's mobile/web app platform. It can cover common mobile backend needs such as app configuration, authentication, database, cloud functions, analytics, crash reporting, app distribution, and messaging.

### Why choose it

Firebase is the fastest path if the early backend is mostly:

- Feature flags / remote config.
- Crash reporting.
- Lightweight telemetry.
- Basic account identity later.
- Mobile-first operational tooling.

### Strengths

- Very mobile-app friendly.
- Strong Android fit.
- Good for a small team.
- Remote Config and Crashlytics are natural fits for early needs.
- Reduces the amount of custom backend code required early.

### Risks / Tradeoffs

- Can encourage coupling to Google/Firebase-specific patterns.
- Firestore/Realtime Database are not traditional relational databases.
- Marketplace-style data may become harder to reason about if modeled casually.
- Analytics needs privacy review and intentional event design.
- Easy to add too much too soon.

### Best use for ChromaGlow

Choose Firebase if the near-term goal is operational safety:

- See crashes.
- Gate risky features.
- Measure discovery/pairing failures.
- Avoid building custom backend infrastructure early.

## Option B: Supabase + Sentry

### What it is

Supabase provides a hosted Postgres database, Auth, Storage, Realtime capabilities, and Edge Functions. Sentry provides crash/error/performance monitoring.

### Why choose it

Supabase + Sentry is a better fit if the long-term backend is expected to become a real product backend for Marketplace-style scene sharing.

### Strengths

- Postgres is easier to model for Marketplace data.
- SQL is familiar and portable.
- Supabase Auth + Row Level Security can support user-owned data.
- Sentry is strong for crash/error visibility across platforms.
- Cleaner separation between product database and observability.

### Risks / Tradeoffs

- More backend design responsibility.
- More moving parts than Firebase alone.
- Feature flags may need a custom table/service or a third-party tool.
- Less turnkey than Firebase for mobile teams.
- Requires stricter database/security design from the start.

### Best use for ChromaGlow

Choose Supabase + Sentry if the near-term team is willing to do a little more setup in exchange for a stronger future path toward:

- Scene marketplace.
- User accounts.
- Public/private shared presets.
- Moderation/admin tooling.
- Portable SQL-backed data.

## Recommendation

Start with a decision discussion, not implementation.

My current recommendation:

- Use a local/static feature flag interface first.
- Delay account creation until Marketplace scope requires it.
- For telemetry/crashes, choose the smallest toolset that answers operational questions.
- If Brian wants the fastest mobile-native setup: Firebase.
- If the team wants the cleanest Marketplace future: Supabase + Sentry.

## Source Links

- Firebase: https://firebase.google.com/
- Supabase Docs: https://supabase.com/docs
- Supabase Edge Functions: https://supabase.com/docs/guides/functions
- Sentry Mobile Monitoring: https://sentry.io/solutions/mobile-developers/
