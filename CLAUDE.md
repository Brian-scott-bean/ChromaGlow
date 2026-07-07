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

Important current facts (2026-07-07):

- iOS scheme is `HueHome 1`, not `HueHome` (`run_tests.sh` still names the wrong one — pass the
  scheme explicitly). Validate with:
  `xcodebuild test -project HueHome.xcodeproj -scheme "HueHome 1" -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.
- **`main` is the branch Brian installs from** (Xcode → physical iPhone). Keep it releasable;
  fast-forward validated work to it. Current: `main` @ `6e8a34a`, 0.9.0 build 9.
- Brian's conventions: `checkpoint/*` rollback tag before any multi-commit run; bump
  `CURRENT_PROJECT_VERSION` (all 12 pbxproj entries) each device-test round; one shippable
  commit per fix.
- The freshest "where are we / what's next" is the DEVLOG "Current Status Snapshot" — as of now:
  build 9 awaits Brian's on-device fresh-install verification, then the TEMP `⏱️PERF` prints get
  removed in a cleanup commit.
- Android exists under `android/`; demo MVP + pairing foundations are on `main`, Batch 4 live
  pairing awaits its physical link-button gate on `integration/parallel-batch-4`.
- Parallel multi-agent work follows the "Parallel Agent Pipeline" section in `AGENTS.md`; the lane registry and shared Claude⇄Codex Decision Log live in `docs/coordination/parallel-agent-pipeline.md`.
- After meaningful work, append a dated `[Claude]` entry to `DEVLOG.md`.
