# LikanLabs Homebrew Tap

`Casks/usage-island.rb` is the template for the cask published in
[LikanLabs/homebrew-tap](https://github.com/LikanLabs/homebrew-tap). Edit it
here. The release workflow fills in `version` and `sha256` for each release,
so the values in this copy may be from an older release.

## Automatic updates

When the repository secret `HOMEBREW_TAP_TOKEN` exists, every release updates
the tap after the GitHub release is published. Create the token once:

1. GitHub → **Settings → Developer settings → Fine-grained tokens → Generate
   new token**.
2. Resource owner: **LikanLabs**. Repository access: **Only select
   repositories → homebrew-tap**.
3. Permissions: **Contents: Read and write**. Nothing else.
4. Store it in this repository:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN -R LikanLabs/UsageIsland
   ```

   Paste the token when asked. Renew it before it expires.

## Manual update

Without the token, after each release:

1. Set `version` to the release version without the `v` prefix.
2. Copy the value from `Usage-Island.zip.sha256` into `sha256`.
3. Commit and push the cask to `LikanLabs/homebrew-tap`.

The cask must point only to releases from `LikanLabs/UsageIsland`. Never put
credentials, signing certificates or notarization profiles in the tap.
