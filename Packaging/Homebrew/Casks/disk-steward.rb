cask "disk-steward" do
  version :latest
  sha256 :no_check

  url "https://github.com/KMerdan/disk_steward/archive/refs/heads/main.tar.gz"
  name "Disk Steward"
  desc "Evidence-first disk growth monitor with local read-only agent access"
  homepage "https://github.com/KMerdan/disk_steward"

  disable! date: "2026-09-13", because: "has no notarized release artifact yet"

  depends_on macos: :ventura

  app "Disk Steward.app"

  zap trash: [
    "~/Library/Application Support/Disk Steward",
    "~/Library/Preferences/com.marudankiji.disksteward.plist",
  ]
end
