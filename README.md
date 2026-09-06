# Usage Island

For session continuity and pending validation, read [Docs/HANDOFF.md](Docs/HANDOFF.md).

Native macOS 14+ usage monitor for Codex. A black edge-attached indicator with a circular
meter surrounds the Codex logo, with **used quota** below it. Click it for session/weekly limits and reset times.
Place it on the left, right, or at the top below the notch/menu bar.
The earlier v26 notch views remain in the source tree; the app now launches the
Codex-only edge interface.

## Run

Install and sign in to the Codex CLI first. Usage Island reuses its authentication
through `codex app-server`; it does not read credential files.

```sh
swift run UsageIslandPrototype
```

Click the percentage pill to open or close usage; opening also requests a refresh unless one is already running. Hovering never opens the panel.
Click outside, press Escape, or use the close button to dismiss it. The gear switches
the **same panel** to settings, keeping it above the editor; the back arrow returns
to usage. Page changes animate the black surface over 240 ms, respecting Reduce Motion. Closing settings fades out that page before resetting to usage, so no usage page flashes during dismissal. No separate settings window opens behind other apps.

Settings adjust size (75–150%), Automatic/Español/English, position, and auto-hide.
The black pill attaches to the left/right screen edge or directly below the hardware
notch (below the menu bar on screens without a notch). The visible gap to the panel
is the same in each position. Settings remain open when changing position or size.

With auto-hide enabled, moving the pointer to the edge reveals only the pill;
click it to open details. An open panel or context menu keeps the pill visible.
Preferences apply immediately and persist after relaunch. The context menu offers
refresh and quit. Quota refreshes every minute and can also be refreshed from the
panel. Unavailable usage appears as a dash; stale readings retain their values with
a dashed ring and a message in the detail panel. Ring color follows remaining quota: green above 50%, yellow above 25%, orange above 10%, and red at 10% or less. Settings can show either consumed or available percentage; the number and filled arc follow that choice.

## Build a local app

```sh
./Scripts/package-app.sh
open "dist/Usage Island.app"
```

The resulting app is signed locally for this Mac and built for the host
architecture. It is not notarized for public distribution. It can be opened in
Finder or copied to Applications. No Accessibility or Full Disk Access permission
is needed for quota retrieval.

## Development

```sh
swift build --product UsageIslandPrototype
swift test
```

The XCTest suite requires full Xcode selected as the developer directory;
Command Line Tools alone do not include the required XCTest framework here.
Tests use synthetic provider responses. See `AGENTS.md` for architecture and
security rules. The SVG source and license are in `Assets/OpenAI/`.

## Recovery and verification

Quota refreshes pause during system sleep. On wake, the last reading is marked
stale until a fresh response arrives. A failed Codex process is retired and
recreated on the next refresh, with a new protocol handshake. Authentication and
missing-quota errors keep the same process; they do not create restart loops.

The panel stays on the built-in display when available, and falls back to a
remaining display in clamshell mode. It repositions after display, Space, and wake
changes. Its effective scale is reduced on very small screens so the panel fits;
the saved size preference is preserved.

```sh
./Scripts/verify-resilience.sh
```

This runs the same synthetic recovery/lifecycle/geometry scenarios used by
`ResilienceTests`, without requiring XCTest. It supplements **rather than
replaces** `swift test`. No real account responses are recorded as fixtures.

## LikanLabs community distribution

The intended public channel is the `LikanLabs` GitHub organization, followed by
a Homebrew tap. The repository and tap must be created with these names:

```text
LikanLabs/UsageIsland
LikanLabs/homebrew-tap
```

Tagging a commit such as `v0.1.0` runs `.github/workflows/release.yml`. It
builds a universal Apple Silicon/Intel app, creates `Usage-Island.zip`, and
publishes a SHA-256 file. Copy the cask template from
`Distribution/homebrew/Casks/usage-island.rb` into the tap and update its
version and checksum for each release.

Users then install it with:

```sh
brew tap LikanLabs/tap
brew install --cask usage-island
```

This is separate from the Mac App Store. The source remains open under the MIT
license, and users can also build directly with Swift. A release without
Developer ID signing and notarization may show a Gatekeeper warning; the
release workflow is ready for those credentials to be added later.

## Optional Apple distribution hardening

Quit the running app before rebuilding. A Developer ID Application certificate
with its private key must already be installed in Keychain. Use an existing
notarytool Keychain profile; do not put credentials in scripts or the repository.

```sh
USAGE_ISLAND_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./Scripts/package-app.sh
./Scripts/notarize-app.sh usage-island-notary
```

The signed build enables hardened runtime and includes a secure timestamp.
The second command submits to Apple, checks acceptance, staples and validates the
ticket, checks Gatekeeper, and creates `dist/Usage-Island.zip`.
See [Apple's notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

The default local build remains ad-hoc signed and is not a public release.
