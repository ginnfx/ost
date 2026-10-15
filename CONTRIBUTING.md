# Contributing

This is a small personal project. Keep changes focused and check the app you touched.

## Code map

- `ost_tracker/` has the desktop data and competition rules. `backend/api.py` serves them to the Mac, Windows, and Linux apps.
- `OSTTracker/Sources/` has the SwiftUI apps. The Mac calls the Python sidecar; the iPhone uses `IOSLocalBackend` so its main features work offline. If you change a shared rule, check both implementations.
- The desktop apps share an HTTP and WebSocket API in `backend/api.py`. Update affected client models when you change its payloads. JSON keys use `snake_case`.
- `competition-web/` is a separate Next.js app with its own checks in `package.json`.

## Checks

For the Python tests, use Python 3.11 and install `requirements.txt` plus `pytest`:

```bash
python3 -m pip install -r requirements.txt pytest
python3 -m pytest tests -q
```

For the Swift apps, install XcodeGen and run the commands that cover your change:

```bash
cd OSTTracker
xcodegen generate
xcodebuild -project OSTTracker.xcodeproj -scheme OSTTracker -destination 'platform=macOS' build
xcodebuild -project OSTTracker.xcodeproj -scheme OSTTracker -destination 'platform=macOS' test
xcodebuild -project OSTTracker.xcodeproj -scheme OSTTrackerIOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The Python tests run in CI on Mac, Windows, and Linux. The Windows and Linux build scripts are in their `packaging/` folders. Web checks are in `competition-web/package.json`.
