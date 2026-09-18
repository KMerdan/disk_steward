cask "disk-steward" do
  version "1.2.1"
  sha256 "494348588a2b6207898f53aae3a015ee607db601130275557080cc6a1d0d6812"

  url "https://github.com/KMerdan/disk_steward/releases/download/v#{version}/Disk-Steward-#{version}.zip"
  name "Disk Steward"
  desc "Evidence-first disk growth monitor with local read-only agent access"
  homepage "https://github.com/KMerdan/disk_steward"

  depends_on macos: :ventura

  app "Disk Steward.app"

  zap trash: [
    "~/Library/Application Support/Disk Steward",
    "~/Library/Preferences/com.marudankiji.disksteward.plist",
  ]
end
