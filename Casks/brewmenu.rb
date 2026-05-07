cask "brewmenu" do
  version "0.6.0"
  sha256 "705490db8f905431203ea01d8bf29ed6850e2464182f71446673cb81b192c986"

  url "https://github.com/xscit/BrewMenu/releases/download/#{version}/BrewMenu.zip"
  name "BrewMenu"
  desc "Menu bar app for Homebrew"
  homepage "https://github.com/xscit/BrewMenu"

  app "BrewMenu.app"

  zap trash: [
    "~/Library/Application Support/com.whoami.BrewMenu",
    "~/Library/Preferences/com.whoami.BrewMenu.plist",
  ]
end
