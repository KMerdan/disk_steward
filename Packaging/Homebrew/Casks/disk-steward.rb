cask "disk-steward" do
  version "1.4.0"
  sha256 "5901eedffd7a03bd1e93109936903e6be784883e24a6779d7a0a8af6722ff2c1"

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
