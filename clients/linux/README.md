# OST Tracker for Linux

The Linux client is a native **GTK4** app (PyGObject) that talks to the same
Python sidecar as the macOS/Windows apps — it spawns `backend/api.py` with an
embedded python-build-standalone runtime and drives it over the HTTP + `/ws`
contract in `shared/CONTRACT.md`. All business logic stays in Python; this UI
is a thin contract client. Playback uses **GStreamer** (`playbin`).

## Requirements (build machine)

- python-build-standalone fetch uses `curl` + `tar`
- Target systems need GTK4 + GStreamer installed
  (`apt install python3-gi gir1.2-gtk-4.0 gir1.2-gstreamer-1.0`)

## Build

```bash
cd clients/linux
./packaging/build.sh x86_64    # or aarch64
./out/app-x86_64/OSTTracker
```

The script stages a portable bundle (runtime + backend + client + launcher).
AppImage/.deb/.rpm wrapping is a documented follow-up (linuxdeploy/fpm).

## Dev run against the repo checkout

```bash
export OST_SIDECAR_REPO="$PWD"        # repo root
python -m venv .venv-linux && .venv-linux/bin/pip install -r clients/linux/requirements.txt
.venv-linux/bin/python clients/linux/main.py
```

Data lives in `$XDG_DATA_HOME/ost-tracker` or `~/.local/share/ost-tracker`
(mirrors `ost_tracker/config.py`).
