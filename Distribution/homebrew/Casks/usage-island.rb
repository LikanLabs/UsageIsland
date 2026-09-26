cask "usage-island" do
  version "0.1.2"
  sha256 "cc208d81b6109b0f76c4fdc0cfae23d576d36fbfff701bc4d3e06eff8da80165"

  url "https://github.com/LikanLabs/UsageIsland/releases/download/v#{version}/Usage-Island.zip"
  name "Usage Island"
  desc "Codex usage monitor for the macOS menu bar and screen edge"
  homepage "https://github.com/LikanLabs/UsageIsland"

  depends_on macos: :sonoma

  app "Usage Island.app"

  zap trash: "~/Library/Preferences/com.likanlabs.usageisland.plist"
end
