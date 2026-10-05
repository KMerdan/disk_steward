import math
import ctypes as C
import errno
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import sys

from process_supervisor import BirthInfo, Family, MARKER, ProcessTable, expected_survivors, run_command


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


    # TASK-664: any same-user process can be momentarily uninspectable. It is
    # retried within Family.INSPECTION_GRACE; a lasting failure fails closed.
    def test_a_transient_classification_failure_is_retried_not_fatal(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        stranger = {"pid": 400, "unique": 40, "parent": 50, "start": 1, "status": 2}
        calls = []
        class Table:
            def snapshot(self): return {40: stranger}
            def marked(self, *_):
                calls.append(1)
                if len(calls) == 1:
                    raise RuntimeError("Cannot classify new process 400 (errno 0)")
                return False
        times = iter([0.0, 0.5])
        family = Family(Table(), root, "marker", 0, clock=lambda: next(times))
        self.assertEqual(family.discover(), [])
        self.assertEqual(family.discover(), [])
        self.assertEqual(len(calls), 2, "the process was inspected again, not skipped forever")

    def test_a_persistent_classification_failure_still_fails_closed(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        stranger = {"pid": 400, "unique": 40, "parent": 50, "start": 1, "status": 2}
        class Table:
            def snapshot(self): return {40: stranger}
            def marked(self, *_): raise RuntimeError("Cannot classify new process 400 (errno 0)")
        times = iter([0.0, 1.0, 2.5])
        family = Family(Table(), root, "marker", 0, clock=lambda: next(times))
        family.discover()
        family.discover()
        with self.assertRaisesRegex(RuntimeError, "Cannot classify"):
            family.discover()

    def test_a_briefly_unreadable_process_is_retried_and_a_lasting_one_fails(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        class Table:
            def __init__(self): self.unreadable, self.rounds = set(), 0
            def snapshot(self):
                self.rounds += 1
                self.unreadable = {500} if self.rounds in (1, 3, 4, 5) else set()
                return {}
            def marked(self, *_): return False
        times = iter([0.0, 0.5, 1.0, 2.0, 3.5])
        family = Family(Table(), root, "marker", 0, clock=lambda: next(times))
        family.discover()  # first seen at 0.0
        family.discover()  # gone: forgotten
        family.discover()  # seen again at 1.0
        family.discover()  # 1.0 s later: still within the grace
        with self.assertRaisesRegex(OSError, "Cannot establish process identity for 500"):
            family.discover()  # 2.5 s later: fails closed

    def test_processes_unreadable_before_the_run_are_not_waited_on(self):
        root = {"pid": 100, "unique": 10, "parent": 9, "start": 0, "status": 2}
        class Table:
            unreadable = {600}
            def snapshot(self): return {}
            def marked(self, *_): return False
        times = iter([0.0, 10.0])
        family = Family(Table(), root, "marker", 0, baseline_unreadable={600}, clock=lambda: next(times))
        self.assertEqual(family.discover(), [])
        self.assertEqual(family.discover(), [])

    def test_the_inventory_reports_uninspectable_processes_instead_of_failing(self):
        table = object.__new__(ProcessTable)
        class Lib:
            def proc_listpids(self, kind, uid, buffer, size):
                buffer[0], buffer[1] = 100, 200
                return 2 * C.sizeof(C.c_int)
        table.lib = Lib()
        def identity(pid):
            if pid == 200:
                raise OSError(errno.EPERM, "Cannot establish process identity for 200")
            return {"pid": pid, "unique": 1_000 + pid, "status": 2}
        table.identity = identity
        self.assertEqual(list(table.snapshot()), [1_100])
        self.assertEqual(table.unreadable, {200})


class ExpectedDescendantTests(unittest.TestCase):
    """FIND-R4-XCODE-WORKER: a launcher that exits 0 may leave an allowed tool
    daemon (Xcode's ibtoold); it is stopped with cleanup verified and the stage
    passes. Any other survivor, or a failed launcher, still fails the stage."""

    LEAVES_SLEEP = ("import subprocess, sys\n"
                    "subprocess.Popen(['/bin/sleep', '30'], start_new_session=True,"
                    " stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)\n"
                    "sys.exit(int(sys.argv[1]))")

    def run_fixture(self, exit_code, expected):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as directory:
            return run_command([sys.executable, "-c", self.LEAVES_SLEEP, str(exit_code)], Path(directory),
                               {"PATH": "/usr/bin:/bin"}, Path(directory) / "run.log", 20,
                               expected_descendants=expected)

    def test_an_allowed_daemon_is_stopped_and_the_stage_passes(self):
        result = self.run_fixture(0, ["/bin/sleep"])
        self.assertTrue(result["passed"], result["stopReason"])
        self.assertIsNone(result["stopReason"])
        self.assertTrue(result["supervision"]["cleanupVerified"])
        self.assertEqual([item["executable"] for item in result["supervision"]["expectedDescendants"]], ["/bin/sleep"])
        self.assertEqual(result["supervision"]["remaining"], [])

    def test_without_an_allowance_the_survivor_still_fails_the_stage(self):
        result = self.run_fixture(0, [])
        self.assertFalse(result["passed"])
        self.assertEqual(result["stopReason"], "launcher-exited-with-descendants")
        self.assertTrue(result["supervision"]["cleanupVerified"])

    def test_another_executable_or_a_failed_launcher_still_fails(self):
        other = self.run_fixture(0, ["/bin/cat"])
        self.assertEqual(other["stopReason"], "launcher-exited-with-descendants")
        self.assertFalse(other["passed"])
        failed = self.run_fixture(3, ["/bin/sleep"])
        self.assertEqual(failed["stopReason"], "launcher-exited-with-descendants")
        self.assertFalse(failed["passed"])

    def test_an_unreadable_or_relative_path_is_never_allowed(self):
        class Table:
            def executable(self, item): return None if item["pid"] == 2 else "/bin/sleep"
        alive = [{"pid": 1, "unique": 11}, {"pid": 2, "unique": 12}]
        self.assertIsNone(expected_survivors(Table(), alive, ["/bin/sleep"]), "one survivor's path cannot be read")
        self.assertIsNone(expected_survivors(Table(), alive[:1], ["sleep"]), "only absolute paths are allowed")
        self.assertEqual(expected_survivors(Table(), alive[:1], ["/bin/sleep"]),
                         [{"pid": 1, "unique": 11, "executable": "/bin/sleep"}])


if __name__ == "__main__":
    unittest.main()
