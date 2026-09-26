cask "usage-island" do
  version "0.1.3"
  sha256 "124a53575d94fd2b58b56aaf9692d248b5485db6363d9c67bdcc2cb9275d76a6"

  url "https://github.com/LikanLabs/UsageIsland/releases/download/v#{version}/Usage-Island.zip"
  name "Usage Island"
  desc "Codex usage monitor for the macOS menu bar and screen edge"
  homepage "https://github.com/LikanLabs/UsageIsland"

  depends_on macos: :sonoma

  app "Usage Island.app"

  zap trash: "~/Library/Preferences/com.likanlabs.usageisland.plist"
end
