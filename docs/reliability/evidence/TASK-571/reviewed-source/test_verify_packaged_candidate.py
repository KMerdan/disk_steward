import json
from pathlib import Path
import tempfile
import unittest

from verify_packaged_candidate import (SMOKE_FIELDS, bundle_manifest, fixture_identity, helper_transcript,
                                        validate_generated_inputs, validate_helper, validate_smoke)


class PackagedCandidateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ds-package-test-", dir="/private/tmp")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.log = self.root / "check.log"

    def write_smoke(self, changes=None):
        report = dict(SMOKE_FIELDS, support_directory=str(self.root / "ds-smoke-00000000-0000-4000-8000-000000000000"))
        report.update(changes or {})
        self.log.write_text(json.dumps(report) + "\n")
        return report

    def helper_frames(self):
        return [
            {"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2025-06-18",
                "serverInfo": {"name": "disk-witness-mcp", "version": "1"}, "capabilities": {"tools": {}}}},
            {"jsonrpc": "2.0", "id": 2, "result": {"tools": [{"name": "get_storage_summary",
                "inputSchema": {"type": "object", "properties": {}},
                "annotations": {"readOnlyHint": True, "destructiveHint": False}}]}},
            {"jsonrpc": "2.0", "id": 3, "result": {}},
        ]

    def write_frames(self, frames):
        self.log.write_text("\n".join(json.dumps(frame) for frame in frames) + "\n")

    def test_smoke_requires_all_exact_typed_isolation_fields(self):
        valid = self.write_smoke()
        self.assertEqual(validate_smoke(self.log, self.root), valid)
        for key in SMOKE_FIELDS:
            with self.subTest(key=key):
                missing = dict(valid)
                del missing[key]
                self.log.write_text(json.dumps(missing))
                with self.assertRaises(ValueError):
                    validate_smoke(self.log, self.root)
        for change in ({"isolated_smoke": 1}, {"watched_root_count": False}, {"watched_root_count": 1},
                       {"agent_access": "on"}, {"notifications_enabled": "false"}, {"ipc_service": "active"}):
            self.write_smoke(change)
            with self.assertRaises(ValueError):
                validate_smoke(self.log, self.root)

    def test_smoke_rejects_outside_or_retained_scratch_and_duplicate_reports(self):
        self.write_smoke({"support_directory": "/private/tmp/ds-smoke-outside"})
        with self.assertRaises(ValueError):
            validate_smoke(self.log, self.root)
        self.write_smoke()
        self.log.write_text(self.log.read_text() * 2)
        with self.assertRaises(ValueError):
            validate_smoke(self.log, self.root)
        self.write_smoke()
        (self.root / "ds-smoke-00000000-0000-4000-8000-000000000000").mkdir()
        with self.assertRaises(ValueError):
            validate_smoke(self.log, self.root)

    def test_os_temporary_parent_must_be_explicit_and_leaf_must_be_uuid(self):
        os_temporary = self.root / "os-temporary"
        os_temporary.mkdir()
        self.write_smoke({"support_directory": str(os_temporary / "ds-smoke-00000000-0000-4000-8000-000000000000")})
        with self.assertRaises(ValueError):
            validate_smoke(self.log, self.root)
        validate_smoke(self.log, self.root, os_temporary)
        self.write_smoke({"support_directory": str(os_temporary / "ds-smoke-not-a-uuid")})
        with self.assertRaises(ValueError):
            validate_smoke(self.log, self.root, os_temporary)

    def test_generated_project_cannot_hide_changed_product_sources(self):
        original = [{"path": "Sources/A.swift", "sha256": "before"},
                    {"path": "DiskSteward.xcodeproj/project.pbxproj", "sha256": "original"}]
        generated = [original[0], {"path": "DiskSteward.xcodeproj/project.pbxproj", "sha256": "generated"}]
        validate_generated_inputs(original, generated)
        generated[0] = {"path": "Sources/A.swift", "sha256": "changed"}
        with self.assertRaises(ValueError):
            validate_generated_inputs(original, generated)

    def test_bundle_identity_covers_resources_modes_and_rejects_links(self):
        bundle = self.root / "Candidate.app"
        bundle.mkdir()
        resource = bundle / "resource"
        resource.write_text("first")
        first = bundle_manifest(bundle)
        resource.write_text("second")
        self.assertNotEqual(bundle_manifest(bundle), first)
        second = bundle_manifest(bundle)
        resource.chmod(0o700)
        self.assertNotEqual(bundle_manifest(bundle), second)
        (bundle / "linked").symlink_to(resource)
        with self.assertRaises(ValueError):
            bundle_manifest(bundle)

    def test_helper_transcript_never_invokes_evidence_or_self_check(self):
        messages = [json.loads(line) for line in helper_transcript().splitlines()]
        self.assertEqual([message["method"] for message in messages],
                         ["initialize", "notifications/initialized", "tools/list", "ping"])
        self.write_frames(self.helper_frames())
        result = validate_helper(self.log)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["appConnectivity"], "not-tested")

    def test_helper_rejects_missing_duplicate_error_and_unsafe_catalog(self):
        for frames in (self.helper_frames()[:2], self.helper_frames() + [self.helper_frames()[0]]):
            self.write_frames(frames)
            with self.assertRaises(ValueError):
                validate_helper(self.log)
        for changes in ({"name": "delete_files"}, {"annotations": {}},
                        {"annotations": {"readOnlyHint": True, "destructiveHint": True}}):
            frames = self.helper_frames()
            frames[1]["result"]["tools"][0].update(changes)
            self.write_frames(frames)
            with self.assertRaises(ValueError):
                validate_helper(self.log)
        frames = self.helper_frames()
        frames[2]["error"] = {"code": -1}
        self.write_frames(frames)
        with self.assertRaises(ValueError):
            validate_helper(self.log)

    def test_helper_requires_integer_ids_metadata_capabilities_and_input_schema(self):
        for key in ("serverInfo", "capabilities", "protocolVersion"):
            frames = self.helper_frames()
            del frames[0]["result"][key]
            self.write_frames(frames)
            with self.assertRaises(ValueError):
                validate_helper(self.log)
        frames = self.helper_frames()
        frames[0]["id"] = True
        self.write_frames(frames)
        with self.assertRaises(ValueError):
            validate_helper(self.log)
        frames = self.helper_frames()
        del frames[0]["result"]["serverInfo"]["version"]
        self.write_frames(frames)
        with self.assertRaises(ValueError):
            validate_helper(self.log)
        for schema in (None, {}, {"type": "array"}, {"type": "object", "properties": {}, "required": ["missing"]}):
            frames = self.helper_frames()
            frames[1]["result"]["tools"][0]["inputSchema"] = schema
            self.write_frames(frames)
            with self.assertRaises(ValueError):
                validate_helper(self.log)

    def test_sentinel_inventory_detects_new_sidecars_exports_and_directories(self):
        fixture = self.root / "sentinel"
        fixture.mkdir()
        (fixture / "evidence.sqlite").write_text("untouched")
        before = fixture_identity(fixture)
        for name in ("evidence.sqlite-wal", "new-export.json"):
            path = fixture / name
            path.write_text("unexpected")
            self.assertNotEqual(fixture_identity(fixture), before)
            path.unlink()
        (fixture / "unexpected-directory").mkdir()
        self.assertNotEqual(fixture_identity(fixture), before)


if __name__ == "__main__":
    unittest.main()
