import hashlib
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
import uuid
from unittest.mock import patch

from resume_scale import validate_collected_run


class ResumeValidationTests(unittest.TestCase):
    def setUp(self):
        self.data = tempfile.TemporaryDirectory(prefix="disk-steward-530-scale.", dir="/private/tmp")
        self.archive = tempfile.TemporaryDirectory(prefix="disk-steward-530-resume-test.", dir="/private/tmp")
        self.root = Path(self.data.name)
        self.collection = Path(self.archive.name) / "evidence/RESEARCH-530/runs"
        self.target = self.collection / "test-run"
        self.target.mkdir(parents=True)
        (self.root / "fixture").mkdir()
        (self.root / "baseline").mkdir()
        self.token = str(uuid.uuid4())
        (self.root / "owner-token").write_text(self.token)
        self.fixture = {"shape": "wide", "files": 3, "count": 3, "directories": 1, "complete": True}
        artifacts = {"fixture.json": json.dumps(self.fixture), "fixture.log": "fixture done\n",
                     "fixture-supervision.json": json.dumps({"command": ["fixture", "--token", self.token]}),
                     "baseline.log": "baseline stopped\n", "baseline-supervision.json": "{}"}
        for name, value in artifacts.items():
            (self.root / name).write_text(value)
            (self.target / name).write_text(value)
        self.record = {"label": "test-run", "root": str(self.root), "fixture": self.fixture,
                       "supervision": {"reason": "exited", "exitCode": 0},
                       "result": {"schema": "disk-steward-scale-prototype-v1", "status": "time-limit",
                                  "publishedGenerations": 1, "requestedGenerations": 2, "variant": "stream"},
                       "artifactSHA256": {n: hashlib.sha256(v.encode()).hexdigest() for n, v in artifacts.items()}}
        (self.collection / "summary.json").write_text(json.dumps({"runs": [self.record]}))
        connection = sqlite3.connect(self.root / "baseline/evidence.sqlite")
        connection.executescript("""
          CREATE TABLE visible(singleton,generation); INSERT INTO visible VALUES(1,1);
          CREATE TABLE generations(id,mode,status,fenced);
          INSERT INTO generations VALUES(1,'stream','published',0),(2,'stream','preparing',0);
          CREATE TABLE directories(path,parent);
          """)
        connection.executemany("INSERT INTO directories VALUES(?,NULL)", [(str(self.root / "fixture"),)] * 2)
        connection.commit()
        connection.close()

    def tearDown(self):
        self.data.cleanup()
        self.archive.cleanup()

    def test_valid_collected_unfenced_second_generation(self):
        self.assertEqual(validate_collected_run(self.collection, "test-run"), (self.root, self.token, self.fixture, "stream"))

    def test_changed_original_evidence_is_rejected(self):
        (self.root / "baseline.log").write_text("changed")
        with self.assertRaisesRegex(ValueError, "evidence changed"):
            validate_collected_run(self.collection, "test-run")

    def test_prior_resume_is_not_overwritten(self):
        (self.root / "resume.log").write_text("first attempt")
        with self.assertRaisesRegex(ValueError, "previous resume"):
            validate_collected_run(self.collection, "test-run")
        self.assertEqual((self.root / "resume.log").read_text(), "first attempt")

    def test_changed_visible_generation_is_rejected(self):
        connection = sqlite3.connect(self.root / "baseline/evidence.sqlite")
        connection.execute("UPDATE visible SET generation=2")
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(ValueError, "Visible generation changed"):
            validate_collected_run(self.collection, "test-run")

    def test_wrong_owner_token_is_rejected(self):
        (self.root / "owner-token").write_text(str(uuid.uuid4()))
        with self.assertRaisesRegex(ValueError, "supervisor-owned"):
            validate_collected_run(self.collection, "test-run")

    def test_symlink_database_is_rejected(self):
        database = self.root / "baseline/evidence.sqlite"
        relocated = self.root / "baseline/relocated.sqlite"
        database.rename(relocated)
        database.symlink_to(relocated)
        with self.assertRaisesRegex(ValueError, "Unsafe or absent database"):
            validate_collected_run(self.collection, "test-run")

    def test_path_traversal_label_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unsafe run label"):
            validate_collected_run(self.collection, "../test-run")

    def test_non_root_path_outside_fixture_is_rejected(self):
        connection = sqlite3.connect(self.root / "baseline/evidence.sqlite")
        connection.execute("INSERT INTO directories VALUES(?,1)", (str(Path(self.archive.name)),))
        connection.commit()
        connection.close()
        with self.assertRaisesRegex(ValueError, "Database references another fixture"):
            validate_collected_run(self.collection, "test-run")

    def test_incomplete_fixture_is_rejected(self):
        self.fixture["complete"] = False
        value = json.dumps(self.fixture)
        for location in [self.root, self.target]:
            (location / "fixture.json").write_text(value)
        self.record["artifactSHA256"]["fixture.json"] = hashlib.sha256(value.encode()).hexdigest()
        (self.collection / "summary.json").write_text(json.dumps({"runs": [self.record]}))
        with self.assertRaisesRegex(ValueError, "Only complete"):
            validate_collected_run(self.collection, "test-run")

    def test_unsafe_database_family_is_rejected_before_sqlite_open(self):
        for suffix in ["-wal", "-shm"]:
            for link_type in ["symlink", "hardlink"]:
                with self.subTest(suffix=suffix, link_type=link_type):
                    external = Path(self.archive.name) / "external"
                    external.write_bytes(b"must remain unchanged")
                    sidecar = self.root / ("baseline/evidence.sqlite" + suffix)
                    if link_type == "symlink":
                        sidecar.symlink_to(external)
                    else:
                        os.link(external, sidecar)
                    try:
                        with patch("resume_scale.sqlite3.connect", side_effect=AssertionError("SQLite must not open")):
                            with self.assertRaisesRegex(ValueError, "Unsafe or absent database"):
                                validate_collected_run(self.collection, "test-run")
                        self.assertEqual(external.read_bytes(), b"must remain unchanged")
                    finally:
                        sidecar.unlink()

    def test_unexpected_database_sibling_is_rejected_before_sqlite_open(self):
        (self.root / "baseline/unexpected").write_text("preserve")
        with patch("resume_scale.sqlite3.connect", side_effect=AssertionError("SQLite must not open")):
            with self.assertRaisesRegex(ValueError, "Unsafe or absent database"):
                validate_collected_run(self.collection, "test-run")

    def prepare_pinned_stop(self):
        for name in ["resume.log", "resume-supervision.json"]:
            value = "collected pinned admission stop"
            (self.root / name).write_text(value)
            (self.target / name).write_text(value)
            self.record["artifactSHA256"][name] = hashlib.sha256(value.encode()).hexdigest()
        self.record["phase"] = "resume"
        self.record["supervision"]["exitCode"] = 1
        self.record["result"] = {"schema": "disk-steward-scale-resume-v1", "status": "error", "error": "capacity",
                                 "pinnedReader": True, "published": False, "variant": "stream"}
        self.record["postRunDatabase"] = {"queries": {"integrity": {"rows": [["ok"]]}}}
        (self.collection / "summary.json").write_text(json.dumps({"runs": [self.record]}))

    def test_recovery_accepts_only_exact_intact_pinned_admission_stop(self):
        self.prepare_pinned_stop()
        self.assertEqual(validate_collected_run(self.collection, "test-run", "recovery")[3], "stream")
        self.record["result"]["error"] = "corrupt"
        (self.collection / "summary.json").write_text(json.dumps({"runs": [self.record]}))
        with self.assertRaisesRegex(ValueError, "verified intact"):
            validate_collected_run(self.collection, "test-run", "recovery")

    def test_recovery_refuses_to_overwrite_previous_recovery(self):
        self.prepare_pinned_stop()
        (self.root / "recovery.log").write_text("first recovery")
        with self.assertRaisesRegex(ValueError, "previous resume"):
            validate_collected_run(self.collection, "test-run", "recovery")


if __name__ == "__main__":
    unittest.main()
