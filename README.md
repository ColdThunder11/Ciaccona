# Ciaccona

English | [简体中文](README_CN.md)

Ciaccona is a lightweight macOS menu bar utility for per-application audio routing and volume control. With minimal CPU and memory usage, it builds on Core Audio Process Taps to manage individual apps and system alert sounds independently.

> The name *Ciaccona* is inspired by the character Ciaccona in *Wuthering Waves*.

<img src="docs/images/ui-showcase.jpg" alt="Ciaccona UI" width="380" />

## Features

- **Global Output & Software Volume Fallback**
  - Quickly switch the macOS default output device and adjust master volume or mute state from the menu bar popover.
  - Automatically falls back to a software gain/mute pipeline when the selected output device lacks hardware volume or mute controls (such as many HDMI / DisplayPort monitors).

- **Independent System Alert Sound Control**
  - Dedicated System Alert control beneath the global output section supporting Follow System Default or a specific output device, independent volume (0%–150%), and mute.

- **Per-App Volume & Output Device Routing**
  - Detects active and audio-connected apps in real time, grouping helper and renderer subprocesses under their parent app.
  - Per-app output device routing (Follow System Default or a specific device), up to 150% software gain with built-in soft limiting, and per-app mute.
  - **Zero-Overhead Passthrough**: Apps left at 100% volume, unmuted, and following the system default create no Process Tap or private aggregate device.
  - **Persistent Rules**: Custom per-app rules are saved automatically and reapplied whenever the app plays audio again, with right-click reset support.

- **Preferences**
  - Launch at Login (`SMAppService`), in-app language selection (Follow System / English / 简体中文), optional display of all system/menu bar audio processes, optional pausing of idle app audio sessions to save overhead, and 4 audio buffer size presets (Ultra Low / Low / Standard / High).
  - Includes a **Restore Default Audio Routing** button that clears all app and system alert routing rules while keeping application preferences intact.

## Requirements & Permissions

- **OS**: macOS 26.0 or later (Apple Silicon `arm64`)
- **Permission**: On first launch, grant **System Audio Recording** permission in **System Settings → Privacy & Security → Screen & System Audio Recording** so Core Audio Process Taps can capture and route per-app audio.

## Building & Testing

Open `Ciaccona.xcodeproj` in Xcode, or run the test suite from the command line:

```bash
xcodebuild \
  -project Ciaccona.xcodeproj \
  -scheme Ciaccona \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Two GitHub Actions workflows are included:

- `.github/workflows/build.yml`: Runs on `push` or `workflow_dispatch`, executes tests, and uploads the built `.dmg` as a workflow artifact.
- `.github/workflows/release.yml`: Manually triggered via `workflow_dispatch`, runs tests, packages the `.dmg`, and publishes a GitHub Release.

## License

[MIT](LICENSE) © 2026 ColdThunder11
