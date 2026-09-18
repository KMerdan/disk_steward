import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import supervise_scale as bench


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="disk-steward-530-supervisor-test.", dir="/private/tmp")
        self.root = Path(self.directory.name)
        self.environment = {"PATH": "/usr/bin:/bin", "TMPDIR": str(self.root)}

    def tearDown(self):
        self.directory.cleanup()

    def run_child(self, source, seconds=5, cap=128 * bench.MIB):
        with contextlib.redirect_stdout(io.StringIO()):
            return bench.supervise([sys.executable, "-c", source], self.environment, self.root, "test", seconds, cap)

    def test_normal_exit_and_bounded_log(self):
        result = self.run_child('print("complete")')
        self.assertEqual(result["exitCode"], 0)
        self.assertEqual(result["reason"], "exited")
        self.assertEqual((self.root / "test.log").read_text(), "complete\n")

    def test_timeout_terminates_owned_child(self):
        result = self.run_child("import time; time.sleep(30)", seconds=0.2)
        self.assertEqual(result["reason"], "time-limit")
        self.assertLess(result["seconds"], 5)
        self.assertLess(result["exitCode"], 0)

    def test_rss_stop_with_tiny_test_threshold_not_large_allocation(self):
        result = self.run_child("import time; time.sleep(30)", cap=1)
        self.assertEqual(result["reason"], "rss-limit")
        self.assertLess(result["exitCode"], 0)

    def test_sampling_failure_fails_closed_and_reaps_child(self):
        captured = []
        original = bench.subprocess.Popen

        def capture(*args, **kwargs):
            process = original(*args, **kwargs)
            captured.append(process)
            return process

        with patch.object(bench.subprocess, "Popen", side_effect=capture), patch.object(bench, "group_rss", side_effect=RuntimeError("sample failed")):
            with self.assertRaisesRegex(RuntimeError, "sample failed"):
                self.run_child("import time; time.sleep(30)")
        self.assertIsNotNone(captured[0].poll())

    def test_ownership_rejects_nonmatching_leaf_before_fixture_creation(self):
        with self.assertRaises(ValueError):
            bench.fixture_worker(self.root, "invalid", 10, "wide")
        self.assertFalse((self.root / "fixture").exists())

    def test_never_overwrites_previous_log(self):
        self.run_child('print("first")')
        with self.assertRaises(FileExistsError):
            self.run_child('print("second")')
        self.assertEqual((self.root / "test.log").read_text(), "first\n")


if __name__ == "__main__":
    unittest.main()
