# MultiHUD

MultiHUD is a macOS app that adds live data to a virtual camera feed. It is inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** through a CoreMediaIO system extension. You can select it in Zoom, Meet, Teams, and similar apps.
- Combines your webcam feed with live data overlays.
- **Widget overlays**: pills on the video stream. You can set the position of each widget.
  - **Weather**: shows the current temperature and conditions from WeatherKit. It remains visible after a video app replaces the background.
  - **Clock**: shows the current time and time-zone abbreviation.
  - **Meeting timer**: a count-up timer. Start or reset it from the host app or menu bar.
  - **Countdown**: counts down to a clock time that you set. It shows overdue time in red after the target time.
- **Virtual background**: select a JPEG, PNG, HEIC, or another image. The extension separates you from the background with Robust Video Matting or Vision, then places you over the image.
- **Blur background**: blurs your real background without a custom image.
- **Dynamic resolution**: change between 720p and 1080p without reinstalling the extension.
- **Overlay safe areas**: Full Frame, Meeting Safe, Top Strip, and Lower Third profiles keep widgets visible when video apps crop the feed.
- **Camera source selection**: select a physical camera when more than one camera is available.
- **Menu bar extra**: change widget settings and opacity without opening the main window.
- **Auto-launch**: starts the host app when a video app activates the virtual camera.
- **Single host instance**: prevents a Debug launch, URL wake, or second launch from starting two host apps.

## Requirements

- macOS 15.0 or later
- An Apple Developer account with the **WeatherKit** and **System Extension** capabilities for `net.fakeapps.MultiHUD`

## Build and run

```bash
cd MultiHUD
xcodegen generate
xcodebuild -scheme MultiHUD -configuration Debug -allowProvisioningUpdates build
cp -R ~/Library/Developer/Xcode/DerivedData/MultiHUD-*/Build/Products/Debug/MultiHUD.app /Applications/
open /Applications/MultiHUD.app
```

> Run the app from `/Applications`. System extensions need this location.

## Deploy a release build

```bash
cd MultiHUD
bash scripts/deploy.sh
```

The script builds the Release version and verifies its signature. It notarizes and staples the app, installs it in `/Applications`, and starts it. It uses the `MultiHUD` keychain profile with `xcrun notarytool`. Fork maintainers must change the keychain profile name and signing identity in `scripts/deploy.sh`.

## Releases

A `v*` tag starts a GitHub Actions workflow. The workflow builds, signs, notarizes, and publishes a `.dmg` on the [Releases](../../releases) page. Configure these repository secrets:

| Secret | Description |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Base64-encoded Developer ID Application certificate (`.p12`) |
| `P12_PASSWORD` | Password for the `.p12` file |
| `KEYCHAIN_PASSWORD` | Password for the temporary build keychain |
| `MAIN_PROFILE_BASE64` | Base64-encoded provisioning profile for `net.fakeapps.MultiHUD` |
| `EXTENSION_PROFILE_BASE64` | Base64-encoded provisioning profile for `net.fakeapps.MultiHUD.CameraExtension` |
| `APPLE_ID` | Apple ID for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for the Apple ID |

## Architecture

`project.yml` defines two targets. [XcodeGen](https://github.com/yonaskolb/XcodeGen) manages the project.

| Target | Bundle ID | Role |
|---|---|---|
| `MultiHUD` | `net.fakeapps.MultiHUD` | SwiftUI host app that installs the extension and gets weather data |
| `CameraExtension` | `net.fakeapps.MultiHUD.CameraExtension` | CoreMediaIO system extension that captures the webcam and renders overlays |

The host app gets weather data from WeatherKit. It writes the data to the shared app group container. The extension reads these files for the overlay. The extension makes no network calls.

### Shared container files

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `weather.txt` | Host app | Extension | Current temperature and weather symbol (`tempC\|tempF\|symbolName`) |
| `background.jpg` | Host app | Extension | Virtual background image |
| `settings.json` | Host app | Extension | Other configuration values, shown below |

#### `settings.json` schema

```json
{
  "cameraId":       "",
  "blurBackground": false,
  "segQuality":     "fast",
  "resolution":     "720p",
  "opacity":        1.0,
  "overlaySafeArea": "fullFrame",
  "useRVM":         true,
  "widgets": [
    { "type": "weather",   "position": "bottomLeft",  "enabled": true  },
    { "type": "clock",     "position": "bottomLeft",  "enabled": false },
    { "type": "countup",   "position": "bottomRight", "enabled": false, "startedAt": 0.0 },
    { "type": "countdown", "position": "bottomLeft",  "enabled": false, "endsAt": 0.0 }
  ]
}
```

- `position`: `bottomLeft` · `bottomCenter` · `bottomRight` · `topLeft` · `topCenter` · `topRight`
- `overlaySafeArea`: `fullFrame` · `meetingSafe` · `topStrip` · `lowerThird`
- `useRVM`: uses the bundled Robust Video Matting model when `true`. It uses Apple Vision person segmentation when `false`.
- Widgets at the same position appear in one pill. Widgets at different positions appear in separate pills.
- `startedAt` and `endsAt`: Unix timestamps. A value of `0` hides the widget because its timer is not running.

## Tech stack

- Swift and SwiftUI for macOS 15.0 or later
- CoreMediaIO and CMIOExtension for the virtual camera
- WeatherKit and CoreLocation
- AVFoundation for webcam capture
- CoreML and Vision for person segmentation. Robust Video Matting uses the Neural Engine. Vision is the fallback.
- CoreImage, CIFilter, and Metal for compositing. A guided image filter improves edge detail.
