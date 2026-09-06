cask "usage-island" do
  version "0.1.0"
  sha256 "33b95993b71a1d8e4115e352a90d1c2b8fe91de9aa6b9fc52dc14d5e931bd142"

  url "https://github.com/LikanLabs/UsageIsland/releases/download/v#{version}/Usage-Island.zip"
  name "Usage Island"
  desc "Codex usage monitor for the macOS menu bar and screen edge"
  homepage "https://github.com/LikanLabs/UsageIsland"

  app "Usage Island.app"
end
