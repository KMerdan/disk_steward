cask "disk-steward" do
  version "1.2.3"
  sha256 "cec8ad08f15319d1acba71dc7df42c9dd3fa6e875e1ac9d52da2403cb0ee185d"

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
