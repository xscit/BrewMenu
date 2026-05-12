cask "brewmenu" do
  version "0.6.1"
  sha256 "b8873c40f4e4506a0fc9c3392c45e751a0ffc47b80c3328e9bf363cce383eab8"

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
