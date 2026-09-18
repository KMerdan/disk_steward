from pathlib import Path
from contextlib import closing
import sqlite3
import tempfile
import unittest

from probe_dictionary_layout import TABLES, budgeted_rows, probe


class DictionaryLayoutTests(unittest.TestCase):
    def test_sparse_rowids_check_every_512_reconstructed_rows_and_at_end(self):
        processed, checks = [], []
        for row in budgeted_rows(((2 * n + 1,) for n in range(1025)), lambda: checks.append(len(processed))):
            processed.append(row)
        self.assertEqual(checks, [512, 1024, 1025])

    def test_roundtrip_preserves_null_unicode_empty_text_and_sample_times(self):
        with tempfile.TemporaryDirectory(prefix="disk-steward-530-layout-test.", dir="/private/tmp") as directory:
            root = Path(directory)
            (root / "source").mkdir()
            (root / "target").mkdir()
            source, target = root / "source/evidence.sqlite", root / "target/evidence.sqlite"
            with closing(sqlite3.connect(source)) as db, db:
                for table in TABLES:
                    db.execute(f"CREATE TABLE {table}(id TEXT PRIMARY KEY,path TEXT,observed_at REAL,valid_through REAL,note TEXT,bytes INTEGER)")
                    db.executemany(f"INSERT INTO {table} VALUES(?,?,?,?,?,?)", [
                        ("A", "/日本語/é", 123.125, None, "", 0),
                        ("B", "/日本語/é", 125.875, 126.0, None, 4096),
                        ("C", "/replaced", 127.5, None, "unknown", -1),
                    ])
                db.execute("CREATE INDEX bindings_open ON path_bindings(path,observed_at DESC) WHERE valid_through IS NULL")
                # Sparse IDs must not control how often budget checks occur.
                for table in TABLES:
                    db.execute(f"UPDATE {table} SET rowid=rowid*1001")
            result = probe(source, target)
            self.assertEqual(len(result["tables"]), 6)
            for table in result["tables"]:
                self.assertEqual(table["rows"], 3)
                self.assertEqual(table["sourceRowsSHA256"], table["reconstructedRowsSHA256"])
            self.assertEqual(result["tables"][2]["indexes"], 2)
            self.assertFalse(result["productEquivalent"])
            (root / "plain").mkdir()
            control = probe(source, root / "plain/evidence.sqlite", encoding="plain")
            self.assertEqual(control["tables"], result["tables"])
            self.assertEqual(control["dictionaryValues"], 0)
            self.assertEqual(control["pageSize"], result["pageSize"])
            with self.assertRaisesRegex(ValueError, "Never overwrite"):
                probe(source, target)


if __name__ == "__main__":
    unittest.main()
