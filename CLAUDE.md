# camoverlay / MultiHUD

macOS app that overlays live data (starting with weather/temperature) onto a virtual camera feed. Inspired by [PedalHUD](https://github.com/davidmokos/PedalHUD).

## What it does

- Creates a **virtual camera** (via CoreMediaIO system extension) selectable in Zoom, Meet, Teams, etc.
- Composites the real webcam feed with data overlays in real time
- Current overlay: weather and temperature via WeatherKit

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
- CoreGraphics / CoreText (overlay rendering in extension)

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
- Extension does NOT make network calls; host app fetches weather and writes to a shared file
- Adding files: drop in the right folder, run `xcodegen generate`, rebuild
