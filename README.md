# Screenshotter

A menu bar screenshot tool for macOS, like the built-in ⌘⇧4 but with an annotation editor and a history.

## Install

Requires macOS 14 (Sonoma) or later, Apple silicon or Intel.

```sh
brew tap scr2em/screenshotter https://github.com/scr2em/screenshotter
brew install --cask screenshotter
```

Or download the zip from [Releases](https://github.com/scr2em/screenshotter/releases) and move
`Screenshotter.app` to `/Applications`.

**First launch.** The app is not notarized by Apple, so macOS blocks it the first time. Open
System Settings → Privacy & Security, scroll down and click **Open Anyway**.

**Screen Recording permission.** Screenshotter needs it to capture the screen: System Settings →
Privacy & Security → Screen & System Audio Recording → turn on Screenshotter, then quit and reopen it.
Release builds are ad-hoc signed, so macOS may ask again after an upgrade.

**Launch at login** is turned on the first time the app runs. Turn it off in Settings.

## Build from source

Requires Xcode (Swift 5.10+).

```sh
make run        # build build/Screenshotter.app and launch it
make install    # copy to /Applications and launch (recommended: needed for "Launch at login")
```

Local builds are signed with your first "Apple Development" identity when one exists, so the Screen
Recording permission survives rebuilds. With ad-hoc signing (`SIGN_IDENTITY=- make build`), macOS asks
again after every rebuild.

## Using it

Press **⌘⇧2** (change it in Settings) or use the menu bar icon.

**Selecting**
- Drag to select an area. A plain click captures the window under the cursor, or the whole screen if you click the desktop.
- Shift: square selection · hold Space while dragging to move it · Esc or right-click to cancel.

**Editor**

| Tool | Key | | Action | Key |
|---|---|---|---|---|
| Select / move | V | | Done (copy, save to history, close) | ↩ |
| Arrow | A | | Copy | ⌘C |
| Line | L | | Save as PNG | ⌘S |
| Rectangle | R | | Undo / Redo | ⌘Z / ⇧⌘Z |
| Ellipse | O | | Delete selected | ⌫ |
| Pen | P | | Nudge selected | arrow keys (⇧ = 10pt) |
| Highlighter | H | | Pick palette color | 1–9 |
| Text | T | | | |
| Pixelate | B | | | |

- Hold Shift while drawing to snap lines to 45° and make squares/circles.
- With the select tool: drag shapes to move them, drag the handles to resize, double-click text to edit it.
  Changing color or size applies to the selected shape.
- Text: click to type, Return to finish, Shift+Return for a new line.

**History**: menu bar → Show History… (⌘Y). Double-click a screenshot to edit its annotations again, drag
it into other apps, or right-click for copy / save / reveal / delete. Stored in
`~/Library/Application Support/Screenshotter/History` (the original, the annotated version and the
editable annotations for each capture).

## Project layout

```
Sources/Screenshotter/
  App/        entry point, AppDelegate (menu bar item, capture flow, windows), main menu, debug harness
  Capture/    ScreenCaptureKit snapshots, window detection, selection overlay
  Editor/     annotation model, renderer, canvas view, toolbar, editor window
  History/    on-disk store and history browser
  Settings/   preferences, shortcut model, settings window
  Support/    global hotkey (Carbon), clipboard, PNG encoding, permission helpers
Scripts/      build_app.sh (bundles + signs the .app), make_icon.swift
```

## Self-test

A debug build includes a harness that drives the editor with synthetic input, checks drawing, selection,
undo and history, and writes snapshots of every window:

```sh
swift build
SCREENSHOTTER_HISTORY_DIR=/tmp/ss-history .build/debug/Screenshotter --debug-harness /tmp/ss-out
```

## Releasing

```sh
GH_TOKEN=$(gh auth token --user scr2em) make release VERSION=0.2.0
```

`Scripts/release.sh` sets the version, builds a universal ad-hoc signed app, updates the sha256 in
`Casks/screenshotter.rb`, commits, tags, pushes and uploads the zip to GitHub Releases.

## License

MIT
