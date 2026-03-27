# MultiHUD

macOS app that overlays live data onto a virtual camera feed. Inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites the real webcam feed with data overlays in real time
- **Widget overlay system** — weather, clock, meeting timer, and countdown widgets; each independently enabled and positionable at 5 corners/center; widgets sharing a position are grouped into one pill
- Weather/temperature overlay via WeatherKit (survives video-app background replacement)
- Clock widget — live `HH:mm TZ` rendered each frame
- Meeting countup timer — start/reset from host app or menu bar; elapsed time computed from `startedAt` Unix timestamp
- Countdown timer — target clock time set via `DatePicker`; remaining time computed from `endsAt` Unix timestamp
- Virtual background via Vision person segmentation (`VNGeneratePersonSegmentationRequest`)
- Blur background option (Gaussian blur of webcam feed via person mask)
- Dynamic resolution switching — 720p / 1080p via dual `CMIOExtensionStreamFormat`, no reinstall needed
- Camera source selection when multiple cameras are present
- Menu bar extra (`MenuBarView`) — quick-access toggles for widgets, blur, opacity
- Auto-launches host app when a video app activates the virtual camera (`multihud://wake` URL scheme)

## Project location

All code lives under `MultiHUD/` (the Xcode project name).

## Architecture

Two targets managed by XcodeGen (`MultiHUD/project.yml`):

| Target | Bundle ID | Role |
|---|---|---|
| `MultiHUD` | `net.fakeapps.MultiHUD` | Host app (SwiftUI, installs extension, fetches weather) |
| `CameraExtension` | `net.fakeapps.MultiHUD.CameraExtension` | CoreMediaIO system extension — captures webcam, composites overlay |

Team ID: `HGS3GTCF73`

## Tech stack

- Swift 5, macOS 15.0+
- SwiftUI (host app)
- CoreMediaIO / CMIOExtension (virtual camera)
- WeatherKit + CoreLocation (host app only — extension reads weather from shared file)
- AVFoundation (webcam capture in extension)
- Vision / `VNGeneratePersonSegmentationRequest` (person segmentation for virtual background)
- CoreImage / CIFilter (compositing pipeline in extension)

## Key files

- `MultiHUD/project.yml` — XcodeGen spec (source of truth for project structure)
- `MultiHUD/MultiHUD/` — host app source
- `MultiHUD/CameraExtension/` — extension source

## Build & run

```bash
cd MultiHUD
xcodegen generate
xcodebuild -scheme MultiHUD -configuration Debug -allowProvisioningUpdates build
# System extensions require the app to be in /Applications
cp -R ~/Library/Developer/Xcode/DerivedData/MultiHUD-*/Build/Products/Debug/MultiHUD.app /Applications/
open /Applications/MultiHUD.app
```

## Deploy (Release + notarize + install)

```bash
cd MultiHUD
bash scripts/deploy.sh
```

Builds Release, verifies signature, notarizes via `xcrun notarytool` (keychain profile `MultiHUD`), staples, installs to `/Applications`, and relaunches the app.

## Development notes

- **Never edit the `.xcodeproj` directly** — always edit `project.yml` and run `xcodegen generate`
- **WeatherKit** must be enabled in Apple Developer portal for `net.fakeapps.MultiHUD` (host app only — extension does NOT use WeatherKit)
- **System Extension** capability must be enabled in portal for `net.fakeapps.MultiHUD`
- No `systemextensionsctl developer on` needed — use Developer ID Application signing
- Extension does NOT make network calls; host app fetches weather and writes to shared app group container
- Shared container files: `weather.txt` (weather data, written frequently), `background.jpg` (binary), `settings.json` (all other config)
- `settings.json` schema: `{ "cameraId": "", "blurBackground": false, "segQuality": "fast", "resolution": "720p", "opacity": 1.0, "widgets": [{ "type": "weather|clock|countup|countdown", "position": "bottomLeft|...", "enabled": bool, "startedAt": 0.0, "endsAt": 0.0 }] }`
- All settings managed by `AppSettings` (@Observable, @MainActor) — single instance shared via SwiftUI environment across both ContentView instances (WindowGroup + MenuBarExtra)
- Extension reads `background.jpg` modification date each frame to detect changes without polling
- URL scheme `multihud://` registered in host app; extension opens `multihud://wake` via `NSWorkspace` on `startStreaming()` to auto-launch the host app
- Adding files: drop in the right folder, run `xcodegen generate`, rebuild
- **Resolution switching**: extension registers both 720p (`fmt720`) and 1080p (`fmt1080`) `CMIOExtensionStreamFormat` at init. AVFoundation selects the active format via `setStreamProperties(activeFormatIndex:)` → `applyResolutionIndex` on the streaming queue. Settings changes fire via Darwin notify → `notifyActiveFormatChanged` updates the stream.
- **Preview session retry**: `ContentView` uses `.task(id: ext.state.isActive)` with up to 6 retries (300 ms apart) to start the preview — the CMIOExtension device may not be in the discovery list immediately after the activation callback fires.
- **GitHub Actions release**: workflow triggers on `v*` tags; requires 7 repository secrets (certificate, provisioning profiles, Apple ID). Use `git tag v<version>` when releasing.
- **Logger**: extension uses `Logger(subsystem: "net.fakeapps.MultiHUD.CameraExtension", category: "camera")` at `.log()` (default) level — visible in `log show` for signed builds. Host app uses `Logger(subsystem: "net.fakeapps.MultiHUD", category: "preview")`.
- **Log command**: use `/usr/bin/log` not `log` — zsh has a conflicting built-in. E.g. `/usr/bin/log show --predicate 'process == "net.fakeapps.MultiHUD.CameraExtension"' --last 5m`
