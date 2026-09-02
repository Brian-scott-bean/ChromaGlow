# CLAUDE.md - Claude Code Entry Point

Claude Code should use `AGENTS.md` as the canonical ChromaGlow project context.

Read order:

1. Read `AGENTS.md` completely.
2. Read the "Current Status Snapshot" at the top of `DEVLOG.md`.
3. Read the latest relevant entries in `DEVLOG.md`.
4. Read scoped docs under `docs/ios/` or `docs/android/` for the active task.
5. Read `DEVDOC.md`, `COMPOSER_SPEC.md`, `CURSOR_KICKOFF.md`, `.cursorrules`, and `.cursor/rules/*.mdc` when touching iOS, Studio, Composer, Xcode project structure, or Cursor-era areas.
6. Confirm branch, scope, files to touch, and validation plan before editing.

Do not duplicate project strategy here. If strategy, status, rules, commands, or source-of-truth mappings change, update `AGENTS.md` and append `DEVLOG.md`.

Important current facts (2026-07-10):

- iOS scheme is `HueHome 1`, not `HueHome`. `run_tests.sh` targets the correct scheme and picks a
  deterministic simulator (preferred model at the highest installed OS; `CHROMAGLOW_TEST_UDID` /
  `CHROMAGLOW_TEST_MODEL` overrides). When invoking xcodebuild directly, use an exact `id=`
  destination — several simulators share the name `iPhone 17 Pro`, so a bare `name=` is ambiguous.
- **`main` is the branch Brian installs from** (Xcode → physical iPhone). Keep it releasable;
  fast-forward validated work to it. Current: `main`, 1.0.0 build 28 (see DEVLOG snapshot).
- Brian's conventions: `checkpoint/*` rollback tag before any multi-commit run; bump
  `CURRENT_PROJECT_VERSION` (all 12 pbxproj entries) each device-test round; one shippable
  commit per fix.
- The freshest "where are we / what's next" is the DEVLOG "Current Status Snapshot" — as of now:
  build 28 (2026-07-15) = the final audit + Welcome Tour run (35 more Release prints gated,
  12-page replayable first-launch tour, the hidden-tab photosensitivity-alert fix, cleanups);
  build 27 (2026-07-11) = the App-Store-prep run (trademark/naming fixes, Signify disclaimer,
  photosensitivity notice, debug-print gating, 1.0.0 bump; submission runbook at
  `docs/ios/app-store-submission-runbook.md`); builds 18-26 still await Brian's on-device
  verification (build 26 = FAMILY SHARING COMPLETE: per-guest keys, Profiles & Access + guest
  enforcement, revocation honesty — two-phone checklist in the BUILD 26 entry; build 25 =
  widget-scenes fix + Share Invite Phase 1; build 24 = light-card color copy/paste + the first
  working Siri integration). The TEMP `⏱️PERF` prints were removed in the build-27 run.
- Android exists under `android/`; demo MVP + pairing foundations are on `main`, Batch 4 live
  pairing awaits its physical link-button gate on `integration/parallel-batch-4`.
- Parallel multi-agent work follows the "Parallel Agent Pipeline" section in `AGENTS.md`; the lane registry and shared Claude⇄Codex Decision Log live in `docs/coordination/parallel-agent-pipeline.md`.
- After meaningful work, append a dated `[Claude]` entry to `DEVLOG.md`.
