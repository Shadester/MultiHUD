# MultiHUD

A macOS app that overlays live data onto a virtual camera feed — inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites your real webcam feed with live data overlays in real time
- **Weather overlay** — current temperature and conditions via WeatherKit, always visible even when a video app applies its own background replacement
- **Virtual background** — pick any image (JPEG, PNG, HEIC, …); the extension segments you from the background using Vision and composites you over it each frame
- **Camera source selection** — choose which physical camera to use as the source when multiple cameras are available
- **Auto-launch** — the host app starts automatically the moment a video app activates the virtual camera

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

The host app fetches weather via WeatherKit and writes it to a shared app group container. The extension reads those files to drive the overlay — no network calls from the extension.

### Shared container files

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `weather.txt` | Host app | Extension | Current temperature + weather symbol |
| `camera-id.txt` | Host app | Extension | `uniqueID` of the preferred camera source |
| `background.jpg` | Host app | Extension | Virtual background image |

## Tech Stack

- Swift 5, SwiftUI
- CoreMediaIO / CMIOExtension (virtual camera)
- WeatherKit + CoreLocation
- AVFoundation (webcam capture)
- Vision (`VNGeneratePersonSegmentationRequest`, virtual background)
- CoreImage / CIFilter (compositing pipeline)
