# LikanLabs Homebrew Tap

Create a separate public repository named `LikanLabs/homebrew-tap`, then copy
`Casks/usage-island.rb` into it. For every GitHub release:

1. Set `version` to the release version without the `v` prefix.
2. Copy the SHA-256 value from `Usage-Island.zip.sha256` into `sha256`.
3. Commit the cask update and push it to the tap.

Users can then install the app with:

```sh
brew tap LikanLabs/tap
brew install --cask usage-island
```

After installing it, open it with:

```sh
open -a "Usage Island"
```

You can also open it from the **Applications** folder in Finder. The app runs
in the background beside the notch.

The cask should point only to releases from `LikanLabs/UsageIsland`. Do not
put credentials, signing certificates, or notarization profiles in the tap.
