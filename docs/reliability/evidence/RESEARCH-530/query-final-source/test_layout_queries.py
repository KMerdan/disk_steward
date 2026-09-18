from pathlib import Path
from contextlib import closing
import sqlite3
import tempfile
import unittest

from probe_dictionary_layout import probe
from probe_layout_queries import compare, measure, summarize_runs


class LayoutQueryTests(unittest.TestCase):
    def test_later_success_does_not_hide_an_interrupted_attempt(self):
        completed = {"status": "completed", "seconds": 0.01, "vmStepsLowerBound": 100,
                     "rows": [(42,)], "plan": []}
        interrupted = {**completed, "status": "time-limit", "rows": None}
        for attempts in [[interrupted, completed, completed], [completed, interrupted, completed],
                         [completed, completed, interrupted]]:
            summary, rows = summarize_runs(attempts)
            self.assertEqual(summary["status"], "time-limit")
            self.assertIn("time-limit", summary["attemptStatuses"])
            self.assertIsNone(summary["medianSeconds"])
            self.assertIsNone(summary["rowCount"])
            self.assertIsNone(summary["orderedRowsSHA256"])
            self.assertIsNone(rows)

    def test_completed_attempts_must_have_identical_rows(self):
        completed = {"status": "completed", "seconds": 0.01, "vmStepsLowerBound": 100,
                     "rows": [(42,)], "plan": []}
        summary, rows = summarize_runs([completed, completed, completed])
        self.assertEqual(summary["status"], "completed")
        self.assertEqual(summary["medianSeconds"], 0.01)
        self.assertEqual(rows, [(42,)])
        with self.assertRaisesRegex(ValueError, "changed during repeated measurement"):
            summarize_runs([completed, {**completed, "rows": [(43,)]}])

    def test_step_budget_interrupts_and_connection_remains_usable(self):
        with closing(sqlite3.connect(":memory:")) as db:
            result = measure(db, "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000) SELECT SUM(x) FROM n", step_limit=1000)
            self.assertEqual(result["status"], "vm-step-limit")
            self.assertIsNone(result["rows"])
            self.assertEqual(db.execute("SELECT 42").fetchone(), (42,))

    def test_output_cap_rejects_unbounded_results(self):
        with closing(sqlite3.connect(":memory:")) as db:
            with self.assertRaisesRegex(ValueError, "unbounded query output"):
                measure(db, "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<600) SELECT x FROM n")

    def test_decoded_queries_keep_presence_ties_nulls_and_history(self):
        with tempfile.TemporaryDirectory(prefix="disk-steward-530-query-test.", dir="/private/tmp") as directory:
            root = Path(directory)
            for name in ["source", "plain", "dictionary"]:
                (root / name).mkdir()
            source = root / "source/evidence.sqlite"
            with closing(sqlite3.connect(source)) as db, db:
                db.executescript("""
                    CREATE TABLE file_objects(object_id TEXT PRIMARY KEY,identity_method TEXT);
                    CREATE TABLE current_file_state(object_id TEXT PRIMARY KEY,path TEXT UNIQUE,allocated_bytes INTEGER,
                        modified_at REAL,observed_at REAL,presence TEXT,actionable INTEGER,state_as_of_observation_id TEXT);
                    CREATE INDEX current_bytes ON current_file_state(presence,actionable,allocated_bytes DESC);
                    CREATE TABLE path_bindings(binding_id TEXT PRIMARY KEY,object_id TEXT,path TEXT,valid_from REAL,valid_through REAL,confidence TEXT);
                    CREATE INDEX binding_object ON path_bindings(object_id,path) WHERE valid_through IS NULL;
                    CREATE TABLE file_state_observations(observation_id TEXT,object_id TEXT,path TEXT,observed_at REAL,existence TEXT,confidence TEXT,PRIMARY KEY(observation_id,object_id));
                    CREATE TABLE events(event_id TEXT PRIMARY KEY,path TEXT,observed_at REAL,operation TEXT);
                    CREATE TABLE change_events(event_id TEXT PRIMARY KEY,object_id TEXT,occurred_start REAL,occurred_end REAL);
                """)
                rows = [("Z", "/root/あ", 4096, None, 11.25, "present", 1, "obs"),
                        ("A", "/root/z", 4096, 10.5, 11.25, "present", 1, "obs"),
                        ("B", "/root/absent", 8192, 9.0, 11.25, "absent", 0, "obs"),
                        ("C", "/root/unknown", 8192, None, 11.25, "unknown", 0, "obs")]
                db.executemany("INSERT INTO current_file_state VALUES(?,?,?,?,?,?,?,?)", rows)
                for obj, path, _, _, observed, presence, _, obs in rows:
                    db.execute("INSERT INTO file_objects VALUES(?,?)", (obj, "inode"))
                    db.execute("INSERT INTO path_bindings VALUES(?,?,?,?,?,?)", ("b"+obj, obj, path, 10.0, None if presence == "present" else 11.0, "observed"))
                    db.execute("INSERT INTO file_state_observations VALUES(?,?,?,?,?,?)", (obs,obj,path,observed,presence,"observed"))
                    db.execute("INSERT INTO events VALUES(?,?,?,?)", ("e"+obj,path,observed,"observed"))
                    db.execute("INSERT INTO change_events VALUES(?,?,?,?)", ("e"+obj,obj,None,observed))
            plain_path, encoded_path = root / "plain/evidence.sqlite", root / "dictionary/evidence.sqlite"
            probe(source, plain_path, "plain")
            probe(source, encoded_path, "dictionary")
            with closing(sqlite3.connect(plain_path)) as plain, closing(sqlite3.connect(encoded_path)) as encoded:
                result = compare(plain, encoded)
                self.assertTrue(all(r["equalCompletedRows"] for r in result["queries"]))
                self.assertEqual(result["typedCount"]["rows"], [(2, 8192)])
                correct = measure(encoded, "SELECT path FROM decoded_current_file_state WHERE presence='present' ORDER BY path")
                self.assertEqual(correct["rows"], [("/root/z",), ("/root/あ",)])
                raw = encoded.execute("SELECT d.value FROM current_file_state c JOIN text_values d ON d.id=c.path ORDER BY c.path").fetchall()
                self.assertNotEqual(raw, sorted(raw))


if __name__ == "__main__":
    unittest.main()
