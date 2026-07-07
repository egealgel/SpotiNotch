# SpotiNotch

A **Dynamic-Island-style Spotify widget for the MacBook notch**, in native Swift
+ SwiftUI. It hangs a small black panel from the notch that shows the album art
and a live equalizer while collapsed, and **expands on hover** into full
now-playing info with playback controls.

Built on the same AppleScript backend as
[SpotiWidget](https://github.com/egealgel/SpotiWidget) — no login, no API keys,
no Premium required.

## Features

- Sits at the notch and **expands on hover** (Dynamic Island style)
- Collapsed: album art + animated equalizer flanking the notch
- Expanded: art, song/artist, progress, and **shuffle / prev / play / next / repeat**
- Works with or without a physical notch (falls back to a top-centre pill)
- Menu-bar-less, dock-less; **opens at login** automatically

## Requirements

- macOS 13 (Ventura) or later
- The **Spotify desktop app** installed and running

## Install

1. Download **SpotiNotch.dmg** from the
   [latest release](https://github.com/egealgel/SpotiNotch/releases/latest).
2. Drag **SpotiNotch** into **Applications**.
3. Launch it — first time, **right-click → Open** (not notarized). Allow the
   **Automation** permission so it can talk to Spotify.

**To quit / disable:** System Settings → General → Login Items, or drag the app
to the Trash.

## Build from source

```bash
git clone https://github.com/egealgel/SpotiNotch.git
cd SpotiNotch
./install.sh        # builds and installs to /Applications
```

`./make-dmg.sh` builds a DMG; `./uninstall.sh` removes the app.

## How it works

A borderless, always-on-top `NSPanel` is pinned to the top-centre of the screen
at the notch. `SpotifyController` polls the Spotify app over `osascript` and
publishes now-playing state to the SwiftUI `NotchView`, which animates its window
frame between collapsed and expanded sizes on hover.
