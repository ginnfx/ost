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
- macOS uses a Python sidecar (FastAPI + SQLite). iOS keeps a local offline copy and computes its roster data on-device; Supabase syncs portable changes between signed-in devices.
- The retired PySide6 desktop UI sits in `legacy/` for reference

## Running it

Grab the build for your OS from the Releases tab. macOS and Windows get installers, Linux gets a tarball. You can run the iOS companion on your own device from Xcode; TestFlight distribution requires an Apple Developer Program membership. Mac competition data lives in the app data folder, so updates never touch it.

## macOS startup troubleshooting

If the app reports a sidecar handshake failure, the embedded Python backend may
have exited before it could start. Rebuild with `./install.sh --deps --launch`
to refresh the bundled dependencies. The installer now checks for
`python-multipart`, which the portable import endpoint requires at startup.
Your competition database remains in `~/Library/Application Support/ost-tracker`.

## Use the same competition on an iPhone

The iPhone keeps its own offline data copy, so roster, people, ratings, and notes
remain usable without the Mac or an internet connection. Sign in to the same
Supabase account on both devices when online; the Mac seeds the cloud copy and
the iPhone downloads it, then both devices exchange later changes.

The iPhone can be installed directly from Xcode with a Personal Team; TestFlight
distribution requires an Apple Developer Program membership. On iPhone, Roster,
People, and Notes are in the tab bar. Stats, Batches, History, and the optional
Mac music connection are under More.

Song lookup and streaming from services such as YouTube still use the optional
Mac music service. Pair it on the same trusted local network from **More → Mac
music service**. Core data entry and viewing do not depend on that connection.
