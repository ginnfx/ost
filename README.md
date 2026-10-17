<img width="1024" height="1024" alt="icon" src="https://github.com/user-attachments/assets/354eaccd-eb7e-482c-b020-6663df060826" />

I made this for rating game soundtracks with friends.

## tldr

- Roster, OSTs, ratings, and a notes scratchpad in one place
- Daily listening batches that the host can reorder and pin
- Shows rankings, score spread, rater stats, and slice eliminations
- Finds cover art, plays audio in the app, and remembers titles from past rounds so they aren't submitted twice
- Exports standings as CSV, Markdown, or HTML


<img width="1803" height="1375" alt="Screenshot 2026-10-17 at 9 38 58 PM" src="https://github.com/user-attachments/assets/5772b51e-1f86-4288-9dec-9268a40822a4" />
## Apps

- `OSTTracker/` is the SwiftUI app for iPhone and Mac.
- `clients/windows/` is the WinUI 3 client for Windows (x64 + arm64).
- `clients/linux/` is the GTK4 client for Linux (x86_64 + aarch64).

## Running it

Desktop builds, when available, are on GitHub Releases. To build the Mac app from source, run `./install.sh --launch`. For a development build, `./dev.sh` runs the app directly from the repo.

For iPhone, run `cd OSTTracker && xcodegen generate`, open `OSTTracker.xcodeproj`, and choose the `OSTTrackerIOS` scheme. It targets iOS 26 or later. You can install it from Xcode with a Personal Team; TestFlight needs an Apple Developer Program membership.

See [CONTRIBUTING.md][1] for the test and build commands.

[1]: CONTRIBUTING.md
