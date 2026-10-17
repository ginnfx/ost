# OST Tracker

I made this for rating game soundtracks with friends.

## tldr

- Roster, OSTs, ratings, and a notes scratchpad in one place
- Daily listening batches that the host can reorder and pin
- Shows rankings, score spread, rater stats, and slice eliminations
- Finds cover art, plays audio in the app, and remembers titles from past rounds so they aren't submitted twice
- Exports standings as CSV, Markdown, or HTML

## Apps

- `OSTTracker/` is the SwiftUI app for iPhone and Mac.
- `clients/windows/` is the WinUI 3 client for Windows (x64 + arm64).
- `clients/linux/` is the GTK4 client for Linux (x86_64 + aarch64).

Both desktop ports speak the same sidecar contract (see
`shared/CONTRACT.md`) and mirror the Mac's roster, batches, slices,
reveal, history, notes, covers, playback, add-OST, synced lyrics, and
the idle attract screen.

## Running it

Desktop builds, when available, are on GitHub Releases. To build the Mac app from source, run `./install.sh --launch`. For a development build, `./dev.sh` runs the app directly from the repo.

For iPhone, run `cd OSTTracker && xcodegen generate`, open `OSTTracker.xcodeproj`, and choose the `OSTTrackerIOS` scheme. It targets iOS 26 or later. You can install it from Xcode with a Personal Team; TestFlight needs an Apple Developer Program membership.

See [CONTRIBUTING.md][1] for the test and build commands.

[1]: CONTRIBUTING.md
