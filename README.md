# DynamicNotch

A **Dynamic-Island-style music widget for the MacBook notch**, in native Swift

- SwiftUI. Works with both **Spotify** and **Apple Music**. Collapsed, it
  blends in as a plain notch; **hover over it** and it expands into a full
  now-playing card with artwork, a draggable progress bar, and playback controls.

Built on an AppleScript backend — no login, no API keys, no Premium required.

https://github.com/user-attachments/assets/83abcf88-af4f-4881-845d-0f127a183fd0

<img width="1470" height="225" alt="dynamic notch v3" src="https://github.com/user-attachments/assets/c571551e-1711-4af5-ad65-2613354123c4" />



## Features

- Collapsed: blends in as a plain notch — no clutter, doesn't block nearby
  menu bar icons
- **Hover to expand** into a card with album art, song/artist, and a
  concave "notch ear" shape that flows smoothly out of the physical notch
- Draggable progress bar (seek by dragging), shuffle / prev / play / next /
  repeat, all with a smooth, continuously-updating time display
- **Remaining-time countdown** (-2:31 → -2:30 → …) like the iPhone Dynamic Island
- **Auto-detects** whether Spotify or Apple Music is playing and switches seamlessly
- Works with or without a physical notch (falls back to a top-centre pill)
- Menu-bar-less, dock-less; **opens at login** automatically
- Battery-safe: never auto-launches a closed music app

## Requirements

- macOS 13 (Ventura) or later
- The **Spotify desktop app** and/or **Apple Music** installed

## Install

1. Download **DynamicNotch.dmg** from the
   [latest release](https://github.com/egealgel/DynamicNotch/releases/latest).
2. Drag **DynamicNotch** into **Applications**.
3. Launch it — first time, **right-click → Open** (not notarized). Allow the
   **Automation** permission so it can talk to your music apps.

**To quit / disable:** Right click on the widget → Quit DynamicNotch or System Settings → General → Login Items, or drag the app
to the Trash.

## Build from source

```bash
git clone https://github.com/egealgel/DynamicNotch.git
cd DynamicNotch
./install.sh        # builds and installs to /Applications
```

`./make-dmg.sh` builds a DMG; `./uninstall.sh` removes the app.
