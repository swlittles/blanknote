# Inkwell (working title)

A Markdown notes app for Mac, iPad and iPhone. Every note is a plain `.md` file, the
editor styles Markdown as you type, and the theme uses Claude Code's colours in light and dark.

## Storage

- Notes are files in one folder: iCloud Drive (`iCloud~com~example~inkwell/Documents`) once
  iCloud is set up, otherwise the app's Documents folder (on iOS this shows in the Files app).
  Folders in the app are real folders. Recently Deleted is a hidden `.trash/` folder, emptied after 30 days.
- The first line of a note is its title, and the file is renamed to match.
- Optional YAML front matter holds `pinned`, `tags` and the trash bookkeeping. Keys Inkwell
  doesn't know about are kept as they are. Tags also come from `#tags` in the text.
- Each device keeps a SQLite full-text index in Caches (`Index/notes.sqlite`). It's a cache:
  Settings › Rebuild Search Index recreates it from the files.
- Changes from other devices (iCloud) or other apps (on the Mac) are picked up automatically.
  When iCloud keeps two versions of a note, the other one is saved as a "(conflicted copy)" note.

## Layout

- `Packages/InkwellCore`: platform-independent code (note format, store, search index,
  Markdown highlighter and editing commands). `swift test` runs its tests on the Mac.
- `Inkwell/`: the SwiftUI app. `Editor/` wraps TextKit 2 text views (`UITextView`, `NSTextView`).
- `InkwellUITests/`: iPhone UI tests for typing, checkboxes and search.

## Scripts

- `scripts/build.sh [mac|ios]` generates the project (XcodeGen) and builds.
- `scripts/test.sh [--unit]` runs the unit tests, then the UI tests on the "Inkwell iPhone" simulator.
- `scripts/mac_shot.sh out.png -demo -open "API design" -appearance dark` takes a Mac screenshot.
- `scripts/sim_shot.sh iphone|ipad out.png -demo …` takes a simulator screenshot.
- `swift scripts/render_icon.swift <dir>` renders the app icon.

Launch arguments: `-demo` (fresh sample notes, not yours), `-open "<title>"`,
`-sidebar all|trash|folder:<path>|tag:<tag>`, `-search "<text>"`, `-appearance light|dark`.

## Not done yet

- iCloud container, signing and TestFlight (waiting on the final name)
- Apple Notes import
- Images and attachments (`attachments/` is reserved for them)
- Following `[[wiki links]]` between notes
