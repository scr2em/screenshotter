cask "screenshotter" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/scr2em/screenshotter/releases/download/v#{version}/Screenshotter-#{version}-universal.zip"
  name "Screenshotter"
  desc "Menu bar screenshot tool with annotations and history"
  homepage "https://github.com/scr2em/screenshotter"

  depends_on macos: :sonoma

  app "Screenshotter.app"

  uninstall quit: "io.github.scr2em.Screenshotter"

  zap trash: [
    "~/Library/Application Support/Screenshotter",
    "~/Library/Preferences/io.github.scr2em.Screenshotter.plist",
  ]

  caveats <<~EOS
    Screenshotter is not notarized by Apple. The first time you open it, macOS will block it:
    open System Settings → Privacy & Security and click "Open Anyway".

    It needs Screen Recording permission (Privacy & Security → Screen & System Audio Recording).
    After upgrading, macOS may ask for that permission again.
  EOS
end
