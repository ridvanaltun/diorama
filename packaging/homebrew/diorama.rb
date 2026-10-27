# Homebrew cask template. scripts/release-notes.sh fills in OWNER, the version and the sha256 for each
# release (and adds first-launch caveats to unsigned builds); the release workflow commits the result to
# Casks/diorama.rb on main, since this repository is the tap.
cask "diorama" do
  version "1.0.0"
  sha256 "REPLACE_WITH_SHA256_OF_ZIP"

  url "https://github.com/OWNER/diorama/releases/download/v#{version}/Diorama-#{version}.zip"
  name "Diorama"
  desc "Steer and study the tool results Claude Code receives"
  homepage "https://github.com/OWNER/diorama"

  depends_on macos: :sequoia

  app "Diorama.app"
  binary "#{appdir}/Diorama.app/Contents/Helpers/diorama"

  uninstall launchctl: "io.github.diorama.daemon",
            quit:      "io.github.diorama.Diorama"

  # Takes Diorama's hook out of every connected project's Claude Code settings before the app goes
  # (not on upgrade: Homebrew runs zap only for `brew uninstall --zap`). Hooks left by a plain
  # uninstall do nothing once the CLI is gone.
  zap script: {
        executable:   "/bin/sh",
        args:         ["-c", '[ -x "$1" ] && "$1" hook uninstall --all; exit 0', "sh",
                       "#{appdir}/Diorama.app/Contents/Helpers/diorama"],
        must_succeed: false,
      },
      trash:  "~/Library/Application Support/Diorama"
end
