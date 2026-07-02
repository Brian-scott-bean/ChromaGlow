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

Important current facts:

- iOS scheme is `HueHome 1`, not `HueHome`.
- Android exists under `android/`.
- Android pairing is blocked until TLS bootstrap and canonical bridge identity decisions are made.
- Parallel multi-agent work follows the "Parallel Agent Pipeline" section in `AGENTS.md`; the lane registry and shared Claude⇄Codex Decision Log live in `docs/coordination/parallel-agent-pipeline.md`.
- After meaningful work, append a dated `[Claude]` entry to `DEVLOG.md`.
