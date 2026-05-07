cask "brewmenu" do
  version "0.6.0"
  sha256 "1a73de9f9c10921c1aabf33d564b29c1fd59be1f16233f94672d8d6f883125b4"

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
