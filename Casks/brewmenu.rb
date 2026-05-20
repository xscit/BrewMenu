cask "brewmenu" do
  version "0.6.2"
  sha256 "b8c577a8869d5ccb4ac227d155364e96afc8801ebecaff9b19fd1d49a2197d9e"

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
