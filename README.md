# Inkwell (working title)

A Markdown notes app for Mac, iPad and iPhone. Every note is a plain `.md` file, the
editor styles Markdown as you type, and the theme uses Claude Code's colours in light and dark.

## Storage

- Notes are files in the notes container, one folder per profile: iCloud Drive
  (`iCloud~com~example~inkwell/Documents`) once iCloud is set up, otherwise the app's Documents
  folder (on iOS this shows in the Files app).
  Folders in the app are real folders. Recently Deleted is a hidden `.trash/` folder, emptied after 30 days.
- The first line of a note is its title, and the file is renamed to match.
- Optional YAML front matter holds `pinned`, `tags` and the trash bookkeeping. Keys Inkwell
  doesn't know about are kept as they are. Tags also come from `#tags` in the text.
- Each device keeps a SQLite full-text index per profile in Caches (`Index/<profile id>.sqlite`). It's a cache:
  Settings › Rebuild Search Index recreates it from the files.
- Changes from other devices (iCloud) or other apps (on the Mac) are picked up automatically.
  When iCloud keeps two versions of a note, the other one is saved as a "(conflicted copy)" note.

## Profiles

- A profile is a separate set of notes ("Personal", "Acme Corp"…): its own folders, tags, search
  and Recently Deleted, and its own theme colour, which tints the whole UI. Switch from the top of
  the sidebar, the Profile menu, or ⌃⌘] / ⌃⌘[. Manage them in Settings › Profiles.
- Each profile is a top-level folder of the notes container with a hidden `.inkwell-profile.json`
  (name, theme, order). On first launch, notes from before profiles moved into "Personal". A folder
  created in the container (in Finder, say) becomes a new profile. Deleted profiles move to the
  hidden `.deleted-profiles` folder.
- Every profile syncs to every device on the iCloud account; which profile is open is per device.
- Code: `ProfileStore` and `ProfileTheme`/`ThemeColors` in InkwellCore, `AppModel` in the app.

## Keyboard shortcuts and notifications

- Every command has a default shortcut, and all of them can be changed in Settings › Shortcuts
  (Mac) or Settings › Keyboard Shortcuts (iPad, or iPhone with a keyboard). Defaults and conflict
  rules live in `Packages/InkwellCore/Sources/InkwellCore/Shortcuts.swift`.
- Global hotkeys on the Mac work in any app: ⌃⌥⌘I shows or hides Inkwell, ⌃⌥⌘N starts a note,
  ⌃⌥⌘F searches. They use Carbon `RegisterEventHotKey`, so they need no Accessibility permission.
- iPhone and iPad can't have system-wide hotkeys. The App Shortcuts "New Note" and "Search Notes"
  cover that instead: Siri, Spotlight, the Action Button, Back Tap and the Shortcuts app.
- In-app notifications (`UI/Toasts.swift`) confirm actions, offer Undo for deleting and moving,
  and report reloads, sync conflicts and errors.

## Layout

- `Packages/InkwellCore`: platform-independent code (note format, store, search index,
  Markdown highlighter and editing commands). `swift test` runs its tests on the Mac.
- `Inkwell/`: the SwiftUI app. `Editor/` wraps TextKit 2 text views (`UITextView`, `NSTextView`).
- `InkwellUITests/`: UI tests for typing, checkboxes, search, the theme, Undo, and (on iPad)
  hardware-keyboard shortcuts and the shortcut recorder.

## Scripts

- `scripts/build.sh [mac|ios]` generates the project (XcodeGen) and builds.
- `scripts/test.sh [--unit]` runs the unit tests, then the UI tests on the "Inkwell iPhone" and
  "Inkwell iPad" simulators.
- `scripts/mac_shot.sh out.png -demo -open "API design" -theme dark` takes a Mac screenshot.
- `scripts/sim_shot.sh iphone|ipad out.png -demo …` takes a simulator screenshot.
- `swift scripts/render_icon.swift <dir>` renders the app icon.

Launch arguments: `-demo` (fresh sample notes, not yours), `-open "<title>"`,
`-sidebar all|trash|folder:<path>|tag:<tag>`, `-search "<text>"`, `-theme system|light|dark`,
`-resetShortcuts`, `-profile "<name>"`, and on iPhone/iPad `-settings general|profiles` and
`-newProfile`. Debug Mac builds also take `-themeSelfTest <file>` and `-shortcutSelfTest <file>`
(see `App/DebugSelfTests.swift`).

## Not done yet

- iCloud container, signing and TestFlight (waiting on the final name)
- Apple Notes import
- Images and attachments (`attachments/` is reserved for them)
- Following `[[wiki links]]` between notes
