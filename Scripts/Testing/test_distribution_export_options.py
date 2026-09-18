"""Credential-free regression checks for the manual Developer ID export contract."""
from pathlib import Path
import plistlib
import re
import unittest


class DistributionExportOptionsTests(unittest.TestCase):
    repository = Path(__file__).resolve().parents[2]

    def test_manual_export_selects_the_application_profile(self):
        with (self.repository / "Config/ExportOptions/DeveloperID.plist").open("rb") as stream:
            options = plistlib.load(stream)
        self.assertEqual(options["signingStyle"], "manual")
        self.assertEqual(options.get("provisioningProfiles"), {
            "com.marudankiji.disksteward": "Disk Steward Developer ID Distribution",
        })
        project = (self.repository / "Config/Packaging/project.yml").read_text()
        profiles = re.findall(r"^\s+PROVISIONING_PROFILE_SPECIFIER:\s*(.*?)\s*$", project, re.MULTILINE)
        self.assertIn(options["provisioningProfiles"]["com.marudankiji.disksteward"], profiles)

    def test_template_stays_local_and_developer_id_signed(self):
        with (self.repository / "Config/ExportOptions/DeveloperID.plist").open("rb") as stream:
            options = plistlib.load(stream)
        self.assertEqual(options["destination"], "export")
        self.assertEqual(options["method"], "developer-id")
        self.assertEqual(options["signingCertificate"], "Developer ID Application")
        self.assertEqual(options["teamID"], "G3P6TU385Y")


if __name__ == "__main__":
    unittest.main()
