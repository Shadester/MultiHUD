# camoverlay / MultiHUD

macOS app that overlays live data (starting with weather/temperature) onto a virtual camera feed. Inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites the real webcam feed with data overlays in real time
- Weather/temperature overlay via WeatherKit (pill always rendered on top, survives video-app background replacement)
- Virtual background via Vision person segmentation (`VNGeneratePersonSegmentationRequest`)
- Camera source selection when multiple cameras are present
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

- Swift 5, macOS 26.2+
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

## Development notes

- **Never edit the `.xcodeproj` directly** — always edit `project.yml` and run `xcodegen generate`
- **WeatherKit** must be enabled in Apple Developer portal for `net.fakeapps.MultiHUD` (host app only — extension does NOT use WeatherKit)
- **System Extension** capability must be enabled in portal for `net.fakeapps.MultiHUD`
- No `systemextensionsctl developer on` needed — use Developer ID Application signing
- Extension does NOT make network calls; host app fetches weather and writes to shared app group container
- Shared container files: `weather.txt` (weather data), `camera-id.txt` (selected camera `uniqueID`), `background.jpg` (virtual background image)
- Extension reads `background.jpg` modification date each frame to detect changes without polling
- URL scheme `multihud://` registered in host app; extension opens `multihud://wake` via `NSWorkspace` on `startStreaming()` to auto-launch the host app
- Adding files: drop in the right folder, run `xcodegen generate`, rebuild
