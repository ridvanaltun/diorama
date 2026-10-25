# Homebrew cask template. Fill in OWNER, the version and the sha256 at release time.
cask "diorama" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  url "https://github.com/OWNER/diorama/releases/download/v#{version}/Diorama-#{version}.zip"
  name "Diorama"
  desc "Steer and study the tool results Claude Code receives"
  homepage "https://github.com/OWNER/diorama"

  depends_on macos: ">= :sequoia"

  app "Diorama.app"
  binary "#{appdir}/Diorama.app/Contents/Helpers/diorama"

  uninstall quit: "io.github.diorama.Diorama",
            launchctl: "io.github.diorama.daemon"

  zap trash: "~/Library/Application Support/Diorama"
end
