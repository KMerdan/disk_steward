"""Version metadata must remain consumable by Apple's and Homebrew's parsers."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BundleVersionMetadataTests(unittest.TestCase):
    def test_checked_in_versions_are_nonempty_strings(self):
        with (ROOT / "Config/Packaging/DiskSteward-Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            with self.subTest(key=key):
                self.assertIs(type(info[key]), str)
                self.assertRegex(info[key], r"^[0-9]+(?:\.[0-9]+){0,2}$")

    def test_generator_preserves_string_build_number_and_matches_plist(self):
        source = (ROOT / "Config/Packaging/project.yml").read_text()
        match = re.search(r'^\s+CFBundleVersion:\s+"([0-9]+(?:\.[0-9]+){0,2})"\s*$', source, re.M)
        self.assertIsNotNone(match, "Quote CFBundleVersion; unquoted YAML integers break Homebrew BundleVersion")
        with (ROOT / "Config/Packaging/DiskSteward-Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(match.group(1), info["CFBundleVersion"])

    def test_release_gate_checks_version_types_before_distribution(self):
        gate = (ROOT / "Scripts/Distribution/verify-release").read_text()
        self.assertIn("CFBundleShortVersionString CFBundleVersion", gate)
        self.assertIn("-type", gate)
        self.assertIn('!= "string"', gate)


if __name__ == "__main__":
    unittest.main()
