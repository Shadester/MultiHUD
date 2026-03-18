# MultiHUD

A macOS app that overlays live data onto a virtual camera feed — inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites your real webcam feed with live data overlays in real time
- Current overlay: weather and temperature via WeatherKit

## Requirements

- macOS 26.2+
- Apple Developer account with WeatherKit and System Extension capabilities enabled for `net.fakeapps.MultiHUD`

## Build & Run

```bash
cd MultiHUD
xcodegen generate
xcodebuild -scheme MultiHUD -configuration Debug -allowProvisioningUpdates build
cp -R ~/Library/Developer/Xcode/DerivedData/MultiHUD-*/Build/Products/Debug/MultiHUD.app /Applications/
open /Applications/MultiHUD.app
```

> System extensions require the app to run from `/Applications`.

## Architecture

Two targets defined in `project.yml` (managed by [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

| Target | Bundle ID | Role |
|---|---|---|
| `MultiHUD` | `net.fakeapps.MultiHUD` | Host app — SwiftUI UI, installs the extension, fetches weather |
| `CameraExtension` | `net.fakeapps.MultiHUD.CameraExtension` | CoreMediaIO system extension — captures webcam, renders overlay |

The host app fetches weather via WeatherKit and writes it to a shared file. The extension reads that file to render the overlay — no network calls from the extension.

## Tech Stack

- Swift 5, SwiftUI
- CoreMediaIO / CMIOExtension (virtual camera)
- WeatherKit + CoreLocation
- AVFoundation (webcam capture)
- CoreGraphics / CoreText (overlay rendering)
