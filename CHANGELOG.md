# Changelog

## [0.1.0] - 2026-08

First tagged release — the app goes multi-platform.

### Added
- GitHub Releases pipeline: tag `v*` builds and drafts a release with
  macOS (universal .dmg), Windows (x64 + arm64, NSIS/MSIX), Linux
  (x64 + arm64 bundle), and iOS (.ipa for TestFlight) plus SHA-256 checksums.
- Windows client: native WinUI 3 (C#/.NET 8), same sidecar contract,
  Job Object teardown, MediaPlayer playback.
- Linux client: native GTK4 (PyGObject), GStreamer playback, killpg teardown.
- iOS client: in-process sidecar — embedded CPython runs uvicorn on a thread
  (sandbox forbids subprocesses); readiness via a handshake file.
- Portable competition export/import (`GET /export/portable`,
  `POST /import/portable`): carry a competition between platforms as a zip.
- Per-OS data directories (`config.py`) and a portable sidecar watchdog
  (works without POSIX re-parenting).
- CI test matrix: pytest on macOS, Windows x64 + arm64, Linux x64 + arm64.

### Changed
- Sidecar lifecycle is platform-aware: killpg on POSIX, Job Objects on
  Windows, in-process on iOS.
- `packaging/config.sh` selects the python-build-standalone triplet per arch.

### Removed
- macOS-only assumptions from the Python layer (Application Support path,
  ppid-only watchdog).
