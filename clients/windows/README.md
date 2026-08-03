# OST Tracker for Windows

The Windows client is a native **WinUI 3** app (C#/.NET 8) that talks to the
same Python sidecar as the macOS app — it spawns `backend/api.py` with an
embedded python-build-standalone runtime and drives it over the HTTP + `/ws`
contract in `shared/CONTRACT.md`. All business logic stays in Python; this UI
is a thin contract client.

## Layout

- `OSTTracker/` — the WinUI 3 app (App + MainWindow + pages)
  - `Sidecar/SidecarProcess.cs` — spawns the sidecar, reads the
    `OSTTRACKER_READY` handshake, tears the whole tree down via a **Job Object**
  - `Sidecar/SidecarConfig.cs` — packaged (`python-runtime\python.exe` next to
    the exe) vs dev (repo checkout, `OST_SIDECAR_*` env vars)
  - `Networking/OstClient.cs` + `WsPump.cs` — the contract client (snake_case
    JSON, `X-OST-Token`, `/ws` reconnect pump)
  - `Networking/ContractModels.cs` — DTOs mirroring `shared/CONTRACT.md`
  - `Playback/PlaybackService.cs` — MediaPlayer audio sink
  - `Views/` — the screens (code-built, no XAML per page)
- `packaging/build.ps1` — publish x64/arm64, stage the runtime, ship backend,
  optional MSIX / NSIS

## Build (on Windows)

```powershell
cd clients/windows
./packaging/build.ps1 -Arch x64
./packaging/build.ps1 -Arch arm64
```

Requires the .NET 8 SDK (and NSIS/makensis or the Windows SDK for installers).

## Dev run against the repo checkout

```powershell
$env:OST_SIDECAR_REPO = "C:\path\to\ost"      # repo root
dotnet run --project OSTTracker -c Debug
```

Data lives in `%APPDATA%\ost-tracker` (mirrors `ost_tracker/config.py`).
