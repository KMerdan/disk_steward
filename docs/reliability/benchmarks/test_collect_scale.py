from pathlib import Path
from contextlib import closing
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from collect_scale import inspect_database


class SpaceInspectionTests(unittest.TestCase):
    def test_page_accounting_and_row_oracle(self):
        with tempfile.TemporaryDirectory(prefix="disk-steward-530-inspection.", dir="/private/tmp") as root:
            path = Path(root) / "evidence.sqlite"
            with closing(sqlite3.connect(path)) as db, db:
                db.executescript("""
                    CREATE TABLE current_file_state(presence);
                    CREATE TABLE observation_runs(id);
                    CREATE TABLE scan_generation_entries(id);
                    CREATE TABLE scan_generations(status,processed_entry_count,staged_file_count);
                    CREATE TABLE path_bindings(object_id,path,valid_through);
                """)
                db.executemany("INSERT INTO current_file_state VALUES(?)", [("present",)] * 100)
            result = inspect_database(path)
            query = result["queries"]
            self.assertEqual(query["currentFiles"]["rows"], [(100,)])
            self.assertEqual(query["integrity"]["rows"], [("ok",)])
            rows = query["tableAndIndexPages"].get("rows")
            if rows is None:
                self.assertIn("unavailable", query["tableAndIndexPages"])
            else:
                self.assertEqual(sum(r[1] for r in rows) + query["freePages"]["rows"][0][0],
                                 query["pageCount"]["rows"][0][0])
                self.assertEqual(sum(r[2] for r in rows), sum(r[1] for r in rows) * query["pageSize"]["rows"][0][0])
            self.assertEqual(result["postRunFamilyBytes"]["evidence.sqlite"], path.stat().st_size)

    def test_sidecar_rejected_before_collector_opens_sqlite(self):
        with tempfile.TemporaryDirectory(prefix="disk-steward-530-inspection.", dir="/private/tmp") as root:
            path = Path(root) / "evidence.sqlite"
            path.touch()
            (Path(root) / "evidence.sqlite-wal").symlink_to(path)
            with patch("collect_scale.sqlite3.connect", side_effect=AssertionError("Must not open")):
                with self.assertRaisesRegex(ValueError, "Unsafe or absent database"):
                    inspect_database(path)


if __name__ == "__main__":
    unittest.main()
