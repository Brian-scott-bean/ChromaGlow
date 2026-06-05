# Android NUPnP Fallback Inventory and Gated Deferral (ANDROID-005C)

## Status

- **Task:** ANDROID-005C — Record NUPnP fallback inventory and gated deferral decision
- **Type:** Documentation-only decision record (read-only inventory reviewed and approved)
- **Branch:** `android/nupnp-fallback-inventory`
- **Starting SHA:** `785d085949dc22cf14b20c6948cb0268030f2768`
- **Status:** **DEFERRED** — gated on IOS-BUG-002A
- **No Android fallback behavior implemented in this slice. No network probe performed.**

## Decision

```text
DEFER UNTIL IOS-BUG-002A IS RESOLVED
```

This is a **gated deferral**, not a removal from MVP consideration. The cloud-assisted N-UPnP fallback remains a candidate for a future bounded Android slice; it is held until the upstream iOS cloud-discovery contract is confirmed.

Android continues to ship its landed **local-first onboarding baseline** in the meantime:

- **ANDROID-005A** — mDNS bridge-discovery chooser (explicit chooser rows, no silent auto-selection).
- **ANDROID-005B** — manual endpoint entry (locally parsed, no network resolution).

No Android cloud-assisted discovery code is added in this slice.

## Current Android baseline

The active Android onboarding path is **LAN-only** and is considered complete enough to continue safely:

- Bridge discovery uses on-device mDNS / DNS-SD browse (`_hue._tcp`) surfaced as explicit chooser rows.
- Manual entry parses a user-supplied host locally to a fixed local HTTPS port (`443`) without any network request or DNS resolution.
- Selection is explicit: a chooser row tap or a `Use This Bridge` manual confirmation is required. There is no silent auto-selection.

This baseline does not depend on any cloud-assisted discovery service.

## Existing iOS fallback contract

The current iOS fallback is **cloud-assisted Philips Hue N-UPnP discovery**, not LAN-local SSDP/mDNS and not a local NUPnP query. Recorded behavior of the shipped iOS path:

- URL: `https://discovery.meethue.com/api/nupnp`
- Method: `GET`
- Expects a JSON array, each element with:
  - `id`
  - `internalipaddress`
  - optional `port`
- Defaults the port to `443` when `port` is omitted.
- Runs after approximately **12 seconds** if scanning is still active.
- **Silently chooses the first returned bridge.**
- Does **not** explicitly inspect the HTTP status code before decoding the body.
- Falls into the existing retry path when decoding fails.

This is a narrow cloud-assisted discovery exception. It is distinct from local NUPnP and from SSDP discovery, and it should not be added silently to any platform.

## IOS-BUG-002A evidence

- A physical DEBUG capture observed:
  - request: `GET https://discovery.meethue.com/api/nupnp`
  - response body: `404 page not found`
- The **root cause remains unresolved.**
- It is **not yet known** whether the issue is:
  - endpoint drift,
  - transient service behavior,
  - account- or network-specific behavior, or
  - another external assumption.
- **No fix is claimed in this Android slice.**

## Local-first architecture implications

- Adding this fallback would introduce a **narrow cloud-assisted exception** to Android discovery, which is otherwise LAN-only mDNS plus locally parsed manual entry.
- The existing iOS **silent first-result selection must not be copied into Android.** ANDROID-005A froze:
  - explicit chooser rows, and
  - no silent auto-selection.
- Any future Android fallback must **feed its results into the existing chooser** and require an **explicit row tap**.
- The fallback must remain **optional** and must **never become the mandatory path** for lighting control. LAN discovery and manual entry remain the primary onboarding paths.

## Why implementation is deferred

- The upstream cloud endpoint contract is currently **broken/unverified** (IOS-BUG-002A observed `404 page not found`).
- Implementing an Android client now would either copy an unverified endpoint assumption or risk replicating the iOS silent-auto-select behavior that conflicts with the landed ANDROID-005A explicit-chooser invariant.
- The current Android baseline (mDNS + manual entry) is complete enough to proceed safely without this fallback.
- Therefore the work is gated until the contract is confirmed, rather than removed from consideration.

## Preconditions for any future Android fallback slice

A future Android implementation is gated on all of the following:

1. IOS-BUG-002A confirming the current supported endpoint.
2. Confirmed response shape and explicit HTTP-status behavior.
3. Product approval for the narrow cloud-assisted discovery exception.
4. Product approval that Android cloud results feed the chooser and never silently auto-select.
5. A bounded future Android task packet before any code changes.

A future task ID is **not** frozen by this record. Any follow-up is described here only as a future gated follow-up.

## Future bounded implementation shape

At a high level only (no implementation code or pseudo-code), a future gated slice would consist of:

- one small HTTPS discovery client,
- one pure response parser with JVM coverage,
- explicit HTTP-status handling,
- timeout-triggered invocation only after mDNS yields nothing,
- results merged into existing chooser rows,
- no credentials,
- no pairing,
- no persistence,
- no REST lighting control,
- no TLS trust work,
- no backend dependency.

## Explicit non-goals

This slice does **not**:

- implement Android cloud-assisted fallback behavior,
- issue any network request to Philips or Signify services (no endpoint probe was performed),
- edit Kotlin, Swift, manifest, Gradle, test, or Xcode files,
- claim a fix for IOS-BUG-002A,
- copy the iOS silent first-result selection,
- make cloud discovery mandatory,
- add credentials, pairing, persistence, REST lighting control, TLS trust work, or a backend dependency,
- stage, commit, push, merge, or open a PR.
