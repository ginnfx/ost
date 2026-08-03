# OST Tracker

A small app for running the OST rating competition with my friends.

i made this for osts but you can repurpose it for any other music related media

## just the features

- Roster of n people × n OSTs, everyone rates everything
- Leaderboard with averages, score spread, and per-rater leniency
- **Daily batches**, since its a huge number of soundtracks the host arranges the OSTs into days so raters just hear the audio
- **Slice elimination** for the ranked board cut into bottom bands so eliminations are easy to read
- Cover art fetched automatically (iTunes → MusicBrainz, manual picker as backup), works offline after that
- In-app playback that resolves each OST to a playable stream via yt-dlp, or opens the link in the browser
- Notes scratchpad for OSTs you're still considering, with a promote-to-OST action
- History of past competitions warns you if someone's re-using a title
- Export final standings to CSV, Markdown, or HTML

## swift/other

- SwiftUI on macOS and iOS, WinUI 3 on Windows, GTK4 on Linux
- All the logic and data live in a Python sidecar (FastAPI + SQLite) that the app spawns locally
- The retired PySide6 desktop UI sits in `legacy/` for reference

## Running it

Grab the build for your OS from the Releases tab. macOS and Windows get installers, Linux gets a tarball, iOS builds go to TestFlight. Your data lives in the app data folder for your system, so updates never touch it.
