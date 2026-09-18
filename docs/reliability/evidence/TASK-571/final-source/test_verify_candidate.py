from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

from verify_candidate import (INPUTS, SENTINEL_TEST, clean_environment, copy_inputs,
                              create_output, input_manifest, run_command, sentinel_passed)


class CandidateVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ds-ci-test-", dir="/private/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def fixture(self):
        source = self.root / "source"
        source.mkdir()
        for relative in INPUTS:
            target = source / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if relative == "Package.swift":
                target.write_text("fixture")
            else:
                target.mkdir(parents=True, exist_ok=True)
                (target / "fixture.txt").write_text(relative)
        return source

    def test_environment_is_an_allowlist_not_a_scrubbed_copy(self):
        with patch.dict(os.environ, {"SECRET_SENTINEL": "never-forward", "DISK_STEWARD_NATIVE_CLIENT_TESTS": "1",
                                     "DISK_STEWARD_SCALE_BENCHMARK": "supervised-v1", "DISK_STEWARD_CAPTURE_DIR": "/outside"}):
            environment = clean_environment(self.root)
        for forbidden in ("SECRET_SENTINEL", "DISK_STEWARD_NATIVE_CLIENT_TESTS", "DISK_STEWARD_SCALE_BENCHMARK", "DISK_STEWARD_CAPTURE_DIR"):
            self.assertNotIn(forbidden, environment)
        self.assertEqual(environment["DISK_STEWARD_SUPPORT_DIRECTORY"], str(self.root / "normal-launch-forbidden"))
        self.assertEqual(environment["DISK_STEWARD_SOCKET_PATH"], str(self.root / "never-listening.sock"))

    def test_snapshot_matches_exact_bytes_and_rejects_symlinks(self):
        source = self.fixture()
        manifest = input_manifest(source)
        copy_inputs(source, self.root / "copy", manifest)
        self.assertEqual(input_manifest(self.root / "copy"), manifest)
        (source / "Sources/linked").symlink_to(source / "Package.swift")
        with self.assertRaisesRegex(ValueError, "regular single-link"):
            input_manifest(source)

    def test_copy_rejects_a_changed_source(self):
        source = self.fixture()
        manifest = input_manifest(source)
        (source / "Package.swift").write_text("changed")
        with self.assertRaisesRegex(ValueError, "changed during snapshot"):
            copy_inputs(source, self.root / "copy", manifest)

    def test_manifest_stops_before_materializing_an_unbounded_tree(self):
        source = self.fixture()
        with patch("verify_candidate.MAX_INPUT_ENTRIES", 4):
            with self.assertRaisesRegex(ValueError, "input budget exceeded"):
                input_manifest(source)

    def test_output_never_overwrites_or_targets_the_checkout(self):
        source = self.fixture()
        with self.assertRaises(ValueError):
            create_output(source / "result", source)
        destination = create_output(self.root / "result", source)
        sentinel = destination / "sentinel"
        sentinel.write_text("preserve")
        with self.assertRaises(FileExistsError):
            create_output(destination, source)
        alias = self.root / "alias"
        alias.symlink_to(destination)
        with self.assertRaises(FileExistsError):
            create_output(alias, source)
        self.assertEqual(sentinel.read_text(), "preserve")

    def test_supervision_reports_failure_timeout_and_output_limit(self):
        environment = clean_environment(self.root)
        failed = run_command([sys.executable, "-c", "raise SystemExit(7)"], self.root, environment, self.root / "failed.log", 5)
        self.assertFalse(failed["passed"])
        self.assertEqual(failed["exitCode"], 7)
        timed = run_command([sys.executable, "-c", "import time; time.sleep(10)"], self.root, environment, self.root / "timed.log", 0.1)
        self.assertEqual(timed["stopReason"], "timeout")
        flooded = run_command([sys.executable, "-c", "print('x'*2048)"], self.root, environment, self.root / "flooded.log", 5, 1024)
        self.assertEqual(flooded["stopReason"], "output-limit")
        self.assertFalse(flooded["passed"])
        self.assertEqual((self.root / "flooded.log").stat().st_size, 1024)

    def test_command_success_is_not_mistaken_for_forced_termination(self):
        result = run_command([sys.executable, "-c", "print('done')"], self.root,
                             clean_environment(self.root), self.root / "ok.log", 5)
        self.assertTrue(result["passed"])
        self.assertEqual((self.root / "ok.log").read_text().strip(), "done")

    def test_symlink_input_root_is_rejected(self):
        source = self.fixture()
        (source / "Sources").rename(source / "other")
        (source / "Sources").symlink_to(source / "other", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must not contain symlinks"):
            input_manifest(source)

    def test_skipped_or_just_named_sentinel_is_not_a_pass(self):
        log = self.root / "tests.log"
        for outcome in ("started.", "skipped.", "failed (0.1 seconds)."):
            log.write_text("Test Case '-[IncrementTests.X " + SENTINEL_TEST + "]' " + outcome)
            self.assertFalse(sentinel_passed(log))
        log.write_text("Test Case '-[IncrementTests.X " + SENTINEL_TEST + "]' passed (0.1 seconds).")
        self.assertTrue(sentinel_passed(log))


if __name__ == "__main__":
    unittest.main()
