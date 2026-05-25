# Repo Structure Proposal

## Recommendation

Use one GitHub repo during the migration, with separate top-level areas for iOS, Android, backend, and docs.

Proposed long-term structure:

```text
/
├── ios/
├── android/
├── backend/
├── docs/
│   └── migration/
├── scripts/
└── README.md
```

## Near-Term Reality

The current repo is already an Xcode-centered iOS repo. Do not immediately move every file.

Safer near-term structure:

```text
/
├── ChromaGlow/
├── ChromaGlow.xcodeproj/
├── ChromaGlowWidget/
├── ChromaGlowWatchExtension/
├── ChromaGlowWatchApp/
├── android/                 # new native Android app when created
├── backend/                 # optional/minimal backend when created
├── docs/
│   └── migration/
└── scripts/
```

## Why Same Repo

- Keeps product contracts in one place.
- Keeps Dallin and Brian aligned.
- Makes documentation easier to find.
- Keeps architecture decisions close to implementation.
- Allows iOS and Android changes to reference the same decision records and task packets.

## Why Separate App Folders

- iOS remains native.
- Android remains native.
- Backend remains optional/supporting.
- No false impression that shared code is required.
- Easier to reason about ownership and build tools.

## Rule

Do not reorganize the existing iOS project until both developers can build it successfully and the team has a rollback plan.
