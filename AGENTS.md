# Spatial Folder Canvas — Agent Record

## Product goal

Build a native macOS application that presents the *first-level contents* of a user-selected real folder as a stable, desktop-like spatial canvas.

The product serves people who use spatial memory: documents and folders are recognised by their lasting visual position, not only by names or folder trees.

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
