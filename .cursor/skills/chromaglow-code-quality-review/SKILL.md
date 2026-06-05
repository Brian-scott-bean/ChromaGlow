---
name: chromaglow-code-quality-review
description: >-
  ChromaGlow-specific overlay for thermo-nuclear code-quality reviews.
  Applies repo authority hierarchy, protected iOS surfaces, Android MVP
  guardrails, and task-packet scope discipline. Manual invocation only.
disable-model-invocation: true
---

# ChromaGlow Code Quality Review Overlay

## Prerequisite

Apply the global `thermo-nuclear-code-quality-review` skill first.

This file adds ChromaGlow-specific constraints only. Do not duplicate the global rubric here.

## Authority Hierarchy

Apply the strongest applicable constraint. Frozen architecture decisions and approved task packets jointly constrain the review.

1. Frozen architecture decisions and approved decision records under `docs/`
2. Approved task packet for the active slice
3. `DEVLOG.md`, `DEVDOC.md`, `.cursorrules`, and `.cursor/rules/*.mdc`
4. This overlay and the global thermo-nuclear review skill

A task packet must not override a frozen architecture decision. If a recommendation conflicts with items 1–3, flag and defer it.

## Mode

- Review-only by default.
- Do not edit, create, delete, stage, commit, push, merge, switch branches, or widen scope unless the current task packet explicitly authorizes remediation.
- Do not mix unrelated cleanup into feature slices.
- Convert broad refactors into separate bounded task packets.
- Continue to respect repo rules during review. If a repo rule suggests edits or commits, suppress that action only because this is a review-only pass.

## Protected iOS Surfaces

Treat these existing large iOS files as high-risk protected surfaces:

- `HueHome/Core/Network/UnifiedOrchestrator.swift`
- `HueHome/UI/Studio/StudioView.swift`
- `HueHome/UI/Studio/StudioViewModel.swift`
- `HueHome/UI/Dashboard/DashboardView.swift`
- `HueHome/UI/RoomDetail/RoomDetailView.swift`

Existing oversize is not permission for opportunistic decomposition. Flag new growth, but recommend narrow seams and dedicated follow-up packets instead of drive-by splitting.

## Android Review Guardrails

Treat new Android god-object growth as a blocker.

Be suspicious of:

- Broad repositories
- App-wide managers
- DI frameworks
- Navigation Compose
- New Gradle modules
- Abstractions without a second proven caller
- Broad refactors
- Unrelated cleanup

Prefer small isolated boundaries such as:

- `core.model`
- `core.credentials`
- `core.hue.discovery`
- Future narrow Hue transport boundaries
- Feature-specific UI

## Architecture Preservation

Never recommend violating the frozen platform direction:

- Native iOS production and TestFlight anchor
- Standalone native Android in Kotlin and Jetpack Compose
- Minimal backend only
- No Flutter
- No React Native
- No cross-platform UI rewrite
- LAN-first direct Hue Bridge control
- Approved credential-storage boundary
- Approved mDNS discovery and manual-entry behavior
- Explicit chooser rows; no silent bridge auto-selection
- TLS-bootstrap and canonical bridge-identity blockers remain unresolved until approved decision records land

## Never Invent During Review

Do not propose or implement:

- Trust-all TLS
- Blind `HostnameVerifier`
- Invented TOFU
- Invented pinning
- Invented CA, CN, SAN, or fingerprint rules
- Fabricated bridge identity
- Host or port as durable credential identity
- Credential-store widening
- New secret kinds such as `CLIENT_KEY` persistence
- Backend routing for core Hue control

For findings touching these areas, recommend a bounded decision-record slice instead of code.

## High-Risk Finding Escalation

When a P0 or P1 finding touches protected iOS files, Android pairing/TLS, persistence, or multi-bridge routing:

1. Describe the minimal separate task packet.
2. State the exact file scope.
3. State validation and non-goals.
4. Do not auto-refactor in the current slice.
5. Reference existing inventory or decision docs where available.

## Invocation

Use only when explicitly requested, for example:

`Run the ChromaGlow thermo-nuclear review on this branch.`

Load the global skill first, then this overlay, then return prioritized findings without edits.
