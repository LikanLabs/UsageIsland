# Usage Island

Usage Island is a small native macOS app that shows Codex usage at the edge of
the screen. It can sit on the left, right, or below the MacBook notch and opens
a compact panel with the current quota and reset time.

The project is open source and distributed by the [LikanLabs GitHub
organization](https://github.com/LikanLabs).

## Install

The easiest way to install the latest public release is Homebrew:

```sh
brew tap LikanLabs/tap
brew install --cask usage-island
```

After installing it, open it from Terminal with:

```sh
open -a "Usage Island"
```

You can also open `Usage Island` from the **Applications** folder in Finder.
The app runs in the background and shows the indicator beside the notch; you do
not need to keep Terminal open.

The free release is signed locally but is not notarized with Apple. macOS may
ask you to approve the app the first time you open it. The source and releases
are available in the [Usage Island repository](https://github.com/LikanLabs/UsageIsland).

## Use

Usage Island uses the Codex CLI's existing authentication through `codex app-server`.
It does not read or copy credential files.

- Click the percentage pill to open the usage panel and refresh the value.
- Use the refresh button when you want an immediate update.
- Open the gear to change position, size, language, auto-hide, and the displayed
  percentage (available or consumed).
- Use the back arrow to return to usage, or the close button to dismiss the panel.

The percentage and ring use the same value. The ring changes from green to
yellow, orange, and red as the remaining quota decreases. A stale reading keeps
its last value and is marked in the panel instead of being replaced with a fake
value.

## Build locally

Requirements: macOS 14 or later and full Xcode.

```sh
swift run UsageIslandPrototype
```

To create an app bundle:

```sh
./Scripts/package-app.sh
open "dist/Usage Island.app"
```

The local bundle is signed for development and built for the current Mac. It is
not notarized for public distribution.

## Development checks

```sh
swift build --product UsageIslandPrototype
swift test
./Scripts/verify-resilience.sh
```

Tests use synthetic provider responses. The resilience checks cover refresh
failures, sleep and wake, process recovery, settings transitions, and adaptive
notch geometry.

## Releases

Pushing a version tag such as `v0.1.1` runs the release workflow. It builds an
Apple Silicon and Intel app, creates a ZIP archive, publishes a SHA-256 file,
and attaches both files to the GitHub release.

The Homebrew cask lives in [LikanLabs/homebrew-tap](https://github.com/LikanLabs/homebrew-tap)
and is updated for each release.

## License

Usage Island is released under the [MIT License](LICENSE).
