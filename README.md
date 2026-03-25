# MultiHUD

A macOS app that overlays live data onto a virtual camera feed — inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites your real webcam feed with live data overlays in real time
- **Widget overlays** — compositable pills rendered on the stream, each independently positionable:
  - **Weather** — current temperature and conditions via WeatherKit; survives video-app background replacement
  - **Clock** — live wall clock with timezone abbreviation
  - **Meeting timer** — countup stopwatch, start/reset from the host app or menu bar
  - **Countdown** — counts down to a target clock time you set; stays at 0:00 when reached
- **Virtual background** — pick any image (JPEG, PNG, HEIC, …); the extension segments you using Vision and composites you over it each frame
- **Blur background** — blur your real background without a custom image
- **Dynamic resolution** — switch between 720p and 1080p live without reinstalling the extension
- **Camera source selection** — choose which physical camera to use when multiple cameras are available
- **Menu bar extra** — quick-access toggles for all widgets and opacity, without opening the main window
- **Auto-launch** — the host app starts automatically the moment a video app activates the virtual camera

## Requirements

- macOS 26.2+
- Apple Developer account with **WeatherKit** and **System Extension** capabilities enabled for `net.fakeapps.MultiHUD`

## Build & Run

```bash
cd MultiHUD
xcodegen generate
xcodebuild -scheme MultiHUD -configuration Debug -allowProvisioningUpdates build
cp -R ~/Library/Developer/Xcode/DerivedData/MultiHUD-*/Build/Products/Debug/MultiHUD.app /Applications/
open /Applications/MultiHUD.app
```

> System extensions require the app to run from `/Applications`.

## Deploy (Release build, notarize, install locally)

```bash
cd MultiHUD
bash scripts/deploy.sh
```

Builds Release, verifies signature, notarizes via `xcrun notarytool` (keychain profile `MultiHUD`), staples, installs to `/Applications`, and relaunches the app. The keychain profile name and signing identity are specific to the original developer — fork maintainers will need to update `scripts/deploy.sh` accordingly.

## Releases

Tagged releases (`v*`) trigger a GitHub Actions workflow that builds, signs, notarizes, and publishes a `.dmg` to the [Releases](../../releases) page. The workflow requires the following repository secrets:

| Secret | Description |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Developer ID Application certificate (`.p12`), base64-encoded |
| `P12_PASSWORD` | Password for the `.p12` |
| `KEYCHAIN_PASSWORD` | Temporary keychain password used during the build |
| `MAIN_PROFILE_BASE64` | Provisioning profile for `net.fakeapps.MultiHUD`, base64-encoded |
| `EXTENSION_PROFILE_BASE64` | Provisioning profile for `net.fakeapps.MultiHUD.CameraExtension`, base64-encoded |
| `APPLE_ID` | Apple ID used for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for the Apple ID |

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
| `weather.txt` | Host app | Extension | Current temperature + weather symbol (`tempC\|tempF\|symbolName`) |
| `background.jpg` | Host app | Extension | Virtual background image |
| `settings.json` | Host app | Extension | All other configuration (see below) |

#### `settings.json` schema

```json
{
  "cameraId":       "",
  "blurBackground": false,
  "segQuality":     "fast",
  "resolution":     "720p",
  "opacity":        1.0,
  "widgets": [
    { "type": "weather",   "position": "bottomLeft",  "enabled": true  },
    { "type": "clock",     "position": "bottomLeft",  "enabled": false },
    { "type": "countup",   "position": "bottomRight", "enabled": false, "startedAt": 0.0 },
    { "type": "countdown", "position": "bottomLeft",  "enabled": false, "endsAt": 0.0 }
  ]
}
```

- `position`: `bottomLeft` · `bottomCenter` · `bottomRight` · `topLeft` · `topRight`
- Widgets sharing the same position are grouped into one pill; different positions each get their own pill
- `startedAt` / `endsAt`: Unix timestamps; `0` means not running — the widget is hidden

## Tech Stack

- Swift, SwiftUI — macOS 26.2+
- CoreMediaIO / CMIOExtension (virtual camera)
- WeatherKit + CoreLocation
- AVFoundation (webcam capture)
- Vision (`VNGeneratePersonSegmentationRequest`, virtual background + blur)
- CoreImage / CIFilter (compositing pipeline)
