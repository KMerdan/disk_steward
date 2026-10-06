cask "disk-steward" do
  version "1.5.1"
  sha256 "db26f1fbdf4ce725eadbc25327a144b2e037eed6918d82015db68f79b7642935"

  url "https://github.com/KMerdan/disk_steward/releases/download/v#{version}/Disk-Steward-#{version}.zip"
  name "Disk Steward"
  desc "Evidence-first disk growth monitor with local read-only agent access"
  homepage "https://github.com/KMerdan/disk_steward"

  depends_on macos: ">= :ventura"

  app "Disk Steward.app"
  binary "#{appdir}/Disk Steward.app/Contents/Helpers/disk-witness-mcp"

  zap trash: [
    "~/Library/Application Support/Disk Steward",
    "~/Library/Preferences/com.marudankiji.disksteward.plist",
  ]

  caveats <<~EOS
    Disk Steward includes a Model Context Protocol (MCP) server for development AI:
      disk-witness-mcp (linked into your Homebrew bin PATH)

    To connect your development AI tools (Claude Code, Codex, Cursor, VS Code):
      • In the app: Settings > AI & Agents > turn on "AI Access" and click "Set Up Selected".
      • In Claude Code:
          claude mcp add --scope user disk-steward -- #{HOMEBREW_PREFIX}/bin/disk-witness-mcp
      • In Codex:
          codex mcp add disk-steward -- #{HOMEBREW_PREFIX}/bin/disk-witness-mcp
  EOS
end
