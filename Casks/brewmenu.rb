cask "brewmenu" do
  version "0.6.3"
  sha256 "b01313f20e7df68e3322b594993abdf8ade3db99ea36ffc3a7b335e7d0a8497b"

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
