cask "disk-steward" do
  version "1.2.2"
  sha256 "f7cf38fe52a81f6f96fee84b297d24de2426ca80a62c5c4b65960fc091565a26"

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
