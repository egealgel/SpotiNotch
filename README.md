# SpotiNotch

A **Dynamic-Island-style Spotify widget for the MacBook notch**, in native Swift
+ SwiftUI. Collapsed, it blends in as a plain notch; **hover over it** and it
expands into a full now-playing card with artwork, a draggable progress bar,
and playback controls.

Built on the same AppleScript backend as
[SpotiWidget](https://github.com/egealgel/SpotiWidget) — no login, no API keys,
no Premium required.


https://github.com/user-attachments/assets/8f9a95ce-346c-444b-ad53-eaeab3d70577


<img width="1470" height="233" alt="SpotiNotch2" src="https://github.com/user-attachments/assets/30dfa9f5-e00b-4c15-b8c5-c8aa46aa13c9" />


## Features

- Collapsed: blends in as a plain notch — no clutter, doesn't block nearby
  menu bar icons
- **Hover to expand** into a card with album art, song/artist, and a
  concave "notch ear" shape that flows smoothly out of the physical notch
- Draggable progress bar (seek by dragging), shuffle / prev / play / next /
  repeat, all with a smooth, continuously-updating time display
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

