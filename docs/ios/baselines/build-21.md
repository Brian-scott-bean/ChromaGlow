# iOS TestFlight Build 21 Baseline

## Purpose

This file records the post-build-21 iOS baseline used for stabilization, refactor planning, and Android parity comparison.

The baseline is not simply `main`. The baseline is the exact TestFlight build, git commit, Xcode version, and smoke-tested device state that the team agrees future changes should preserve unless intentionally changed.

## Baseline identity

| Field | Value |
|---|---|
| Product name | ChromaGlow |
| Legacy/project name | HueHome Pro |
| App Store Connect app | TODO: confirm |
| Bundle ID | `com.huehome.pro` |
| Marketing version | TODO: confirm from Xcode/App Store Connect |
| TestFlight build number | `21` |
| Git commit SHA | TODO: fill exact commit used for Build 21 |
| Git tag | TODO: recommended `ios/testflight-build-21` or `baseline/ios-build-21` |
| Xcode version | TODO: fill exact version used to archive |
| Swift version | TODO: confirm from Xcode build settings |
| Minimum iOS target | TODO: confirm; current repo snapshot shows iOS 17.0 |
| Baseline accepted by | TODO: Brian / Dallin |
| Baseline accepted date | TODO: YYYY-MM-DD |

## Archive provenance

| Check | Status | Notes |
|---|---:|---|
| Build archived from clean local state | TODO |  |
| Commit SHA matches archive | TODO |  |
| No uncommitted local changes included | TODO |  |
| App Store Connect build visible | TODO |  |
| TestFlight install verified | TODO |  |
| Known build warnings captured | TODO |  |

## Hardware / environment tested

| Area | Value |
|---|---|
| iPhone model | TODO |
| iOS version | TODO |
| iPad tested | TODO: yes/no/not applicable |
| Apple Watch tested | TODO: yes/no/not applicable |
| WatchOS version | TODO |
| Hue bridge count | TODO |
| Hue bridge firmware version(s) | TODO |
| Light count | TODO |
| Room count | TODO |
| Entertainment area tested | TODO: yes/no |
| Network notes | TODO: Wi-Fi/router/multicast notes |

## Baseline smoke result

| Flow | Required for baseline? | Status | Notes |
|---|---:|---:|---|
| Clean install launch | Yes | TODO |  |
| Existing install upgrade launch | Yes | TODO |  |
| Demo mode launch | Yes | TODO |  |
| Existing paired bridge loads | Yes | TODO |  |
| Bridge discovery | Yes | TODO |  |
| Pairing | Yes | TODO |  |
| Dashboard renders rooms | Yes | TODO |  |
| Room toggle | Yes | TODO |  |
| Brightness control | Yes | TODO |  |
| Color control | Yes | TODO |  |
| Scene activation | Yes | TODO |  |
| Studio opens | Yes | TODO |  |
| Composer apply/save | Yes | TODO |  |
| Sync/music mode start/stop | No, but document if available | TODO |  |
| Widget room action | Yes, if shipped in Build 21 | TODO |  |
| App Intent/Siri action | Yes, if shipped in Build 21 | TODO |  |
| Watch app sync/action | Yes, if shipped in Build 21 | TODO |  |
| Multi-bridge routing | Yes, if supported in Build 21 | TODO |  |
| App relaunch after control action | Yes | TODO |  |
| Offline bridge behavior | Yes | TODO |  |

## Known issues accepted into baseline

Use this section for bugs or rough edges that are already present in Build 21 and should not block the baseline.

| ID | Area | Issue | Severity | Accepted? | Notes |
|---|---|---|---|---:|---|
| IOS-B21-KNOWN-001 | TODO | TODO | TODO | TODO |  |

## Regression guardrails

Until this baseline is replaced by a newer accepted baseline:

- Do not merge behavior-changing iOS PRs without comparing against this file.
- Do not refactor large Swift files unless the affected behavior is documented and smoke-tested.
- Do not change App Group, widget, watch, or credential behavior without updating `docs/ios/persistence-and-credentials.md`.
- Do not change Hue API payloads or routing without updating `docs/ios/hue-contract-inventory.md`.
- Do not treat Android parity assumptions as final unless they match the baseline behavior documented here.

## Replacement rules

A newer baseline may replace Build 21 only when:

1. The replacement TestFlight build is tied to a git commit SHA.
2. Smoke tests are repeated.
3. Known issues are updated.
4. Brian and Dallin agree that the new build is the parity/reference point.
5. This file is either updated or superseded by a new baseline file.
