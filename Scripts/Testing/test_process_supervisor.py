import math
import ctypes as C
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from process_supervisor import BirthInfo, Family, MARKER, ProcessTable, run_command


class SupervisorContractTests(unittest.TestCase):
    def test_marker_read_cannot_adopt_reused_pid(self):
        table = object.__new__(ProcessTable)
        class Sys:
            def sysctl(self, _mib, _count, buffer, _size, *_):
                C.memmove(buffer, (MARKER + "=nonce\0").encode(), len(MARKER) + 7)
                return 0
        table.sys = Sys()
        table.identity = lambda _: {"pid": 100, "unique": 20}
        self.assertFalse(table.marked({"pid": 100, "unique": 10, "status": 2}, "nonce"))

    def test_identity_cannot_mix_metadata_from_two_births(self):
        table = object.__new__(ProcessTable)
        class Lib:
            calls = 0
            def proc_pidinfo(self, _pid, flavor, _arg, pointer, size):
                if flavor == 17:
                    self.calls += 1
                    C.cast(pointer, C.POINTER(BirthInfo)).contents.unique = self.calls
                return size
        table.lib = Lib()
        with self.assertRaisesRegex(RuntimeError, "identity changed"):
            table.identity(100)

    def test_admission_rejects_nonfinite_or_unbounded_budgets_before_launch(self):
        for seconds in (0, -1, math.inf, math.nan, 3601):
            with patch("process_supervisor.subprocess.Popen") as launch:
                with self.assertRaises(ValueError):
                    run_command(["/usr/bin/true"], Path("/private/tmp"), {}, Path("/nonexistent"), seconds)
                launch.assert_not_called()

    def test_missing_inspection_fails_before_launch(self):
        with patch("process_supervisor.subprocess.Popen") as launch:
            def unavailable():
                raise RuntimeError("identity API unavailable")
            with self.assertRaisesRegex(RuntimeError, "identity API"):
                run_command(["/usr/bin/true"], Path("/private/tmp"), {}, Path("/nonexistent"), 1, table_factory=unavailable)
            launch.assert_not_called()

    def test_original_parent_identity_survives_group_and_parent_exit(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        child = {"pid": 200, "unique": 20, "parent": 10, "start": 1, "status": 2, "pgid": 200}
        class Table:
            def snapshot(self): return {20: child}
            def marked(self, *_): return False
        family = Family(Table(), root, "marker", 0)
        self.assertEqual(family.discover(), [child])

    def test_marker_recovers_child_of_already_reaped_intermediate(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        child = {"pid": 300, "unique": 30, "parent": 20, "start": 1, "status": 2}
        stranger = {"pid": 400, "unique": 40, "parent": 9, "start": 1, "status": 2}
        class Table:
            def snapshot(self): return {30: child, 40: stranger}
            def marked(self, item, _): return item == child
        self.assertEqual(Family(Table(), root, "marker", 0).discover(), [child])

    def test_pid_replacement_is_never_signalled(self):
        table = object.__new__(ProcessTable)
        table.identity = lambda _: {"pid": 100, "unique": 99, "status": 2, "uid": os.getuid()}
        with patch("process_supervisor.os.kill") as kill:
            self.assertEqual(table.send({"pid": 100, "unique": 10}, 15), "identity-mismatch")
            kill.assert_not_called()

    def test_wall_clock_rollback_does_not_hide_marked_orphans(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 100, "status": 2}
        child = {"pid": 300, "unique": 30, "parent": 20, "start": 1, "status": 2}
        class Table:
            def snapshot(self): return {30: child}
            def marked(self, *_): return True
        self.assertEqual(Family(Table(), root, "marker", 100, {9}).discover(), [child])

    def test_unrelated_birth_chain_never_needs_environment_inspection(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        stranger = {"pid": 400, "unique": 40, "parent": 9, "start": 1, "status": 2}
        class Table:
            def snapshot(self): return {40: stranger}
            def marked(self, *_): raise AssertionError("Unrelated environment inspected")
        self.assertEqual(Family(Table(), root, "marker", 0, {9}).discover(), [])


if __name__ == "__main__":
    unittest.main()
