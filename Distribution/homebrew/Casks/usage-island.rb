cask "usage-island" do
  version "0.1.4"
  sha256 "62bfda5f2c93180ddbd96331327fb0d9205634f2e9149bec8c985c5e427f61b4"

  url "https://github.com/LikanLabs/UsageIsland/releases/download/v#{version}/Usage-Island.zip"
  name "Usage Island"
  desc "Codex usage monitor for the macOS menu bar and screen edge"
  homepage "https://github.com/LikanLabs/UsageIsland"

  depends_on macos: :sonoma

  app "Usage Island.app"

  zap trash: "~/Library/Preferences/com.likanlabs.usageisland.plist"
end
