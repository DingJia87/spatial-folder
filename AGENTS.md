# Pointer Space — Agent Record

## Product goal

Build a native macOS application that presents the *first-level contents* of a user-selected real folder as a stable, desktop-like spatial canvas.

The product serves people who use spatial memory: documents and folders are recognised by their lasting visual position, not only by names or folder trees.

## Continuation protocol

Before changing code in a new Codex task:

1. Read this file, `README.md`, `docs/CURRENT_STATUS.md`, and `docs/README.md`.
2. Confirm the repository root and run `git status -sb` before editing.
3. Treat `Release/5.1.0/` and `Release/5.2.0/` as frozen usable packages; 5.2.1 and 5.2.2 candidates stay archived in their existing directories, while the current 5.3.0 formal trial belongs in `Release/5.3.0/`. Never overwrite an existing package.
4. Develop on a separate `codex/` branch, preserve real-file safety rules, and run the standard and self-test suites before packaging.
5. Put all user-testable and formal version builds under `Release/<version>/` for discoverability. Mark development candidates clearly, and freeze the formal App/ZIP only after user validation unless the user explicitly asks otherwise.

The live project state and handoff notes are maintained in `docs/CURRENT_STATUS.md`.

## Current handoff (2026-08-11)

- The latest GitHub/public source baseline is `v5.3.0` (build `5300`); the preceding `v5.2.0` baseline is commit `0b19dae`.
- Work remains on branch `codex/5.2.2-write-safety`. The 5.2.1 → 5.2.2 → 5.3.0 safety, recovery, documentation, and toolbar-drag changes form the intentional 5.3.0 release scope. Preserve unrelated user-owned working-tree files; do not reset, clean, revert, or discard them.
- `Assets/Wallpapers/README.md` and `Assets/Wallpapers/SpatialFolder-Graphite-6K.png` are user-owned untracked assets. Do not delete, modify, or stage them unless the user explicitly includes them in scope.
- The local formal trial is `Release/5.3.0/指针空间.app` plus `Release/5.3.0/指针空间.zip`. It is arm64, uses ad-hoc signing, and the ZIP SHA-256 is `506d600de07a636dbec2f1417273afab9b9ce0a34418070e8e41b05d13fc1124`.
- 5.3.0 validation already passed: 22/22 standard tests, 82/82 self-tests, strict Release build, App/ZIP signature verification, and the repeat-package overwrite guard. The 3,000-item scan baseline was 0.14611 seconds and 1,000 journal appends took 0.10017 seconds on the test Mac.
- The user has accepted 5.3.0 for Git publication. The source commit and annotated tag `v5.3.0` are pushed intentionally after reviewing the complete release diff and intended untracked source/docs. Update the GitHub Release/homepage only when specifically requested.
- Never rebuild over `Release/5.3.0/指针空间.app` or its ZIP. If acceptance finds another defect, create a clearly named new candidate artifact or bump the version instead of overwriting the formal trial.

## Non-negotiable behaviour

- The underlying folder and its files are real. The app must never create substitute links or duplicate files merely to display a canvas.
- One chosen folder maps to one saved canvas layout. Reopening it restores positions exactly.
- Only direct children of that folder appear on the canvas.
- Dragging changes canvas metadata only; it must not move the underlying file.
- Files open using macOS's default application. Folders open in Finder.
- Delete means moving the *real* item to the macOS Trash, never simply removing it from the canvas.
- Existing items must not be rearranged when a new item appears; new items land in a predictable inbox area.
- The canvas should preserve familiar desktop affordances: grid snapping, selection, contextual menus, wallpaper, and native file tags where available.

## Contextual menu policy

Replicate core Finder/Desktop file actions in the canvas (open, reveal, rename, copy/cut/paste, tags, quick look, Get Info, share, compress, move to Trash). Third-party Finder-extension actions cannot be guaranteed; always include Reveal in Finder as the escape hatch.

## MVP scope

1. Choose a folder and enumerate direct children.
2. Display Finder-style icons on a wallpapered canvas.
3. Drag icons with grid snapping and persist positions locally.
4. Default-app open for files and Finder open for folders.
5. Create folder, rename, reveal in Finder, and move real items to Trash.
6. Refresh after external folder changes; retain known positions.

## Technical decisions

- SwiftUI UI with AppKit/Foundation file APIs.
- Layout metadata is kept separately from user files under Application Support.
- Use `FileManager.trashItem` for deletions.
- Treat the filesystem as the source of truth; the canvas is only a saved view.

## Out of scope for the first prototype

- Recursive subfolder canvases.
- Arbitrary folder-icon recolouring in Finder (macOS tags are native; app-only visual colour treatment is a later layer).
- Full third-party Finder extension menu parity.
- iCloud conflict handling and sandbox security-scoped bookmarks.
