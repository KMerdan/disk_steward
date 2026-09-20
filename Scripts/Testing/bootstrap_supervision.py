#!/usr/bin/env python3
"""Small independent-watchdog bootstrap. No Swift, user stores or unbounded load."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from process_supervisor import ProcessTable, run_command, MIB

CASES = ("success", "timeout", "detached", "early-exit", "retained-stdout",
         "term-refusal", "memory", "output", "measurement", "cancel", "identity", "gate-close", "legacy-oracle")


def fixture(mode, root):
    # These ceilings are independent of the supervisor being tested. Every
    # branch arms its own terminal timer; no branch allocates above 64 MiB.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(12)
    def record():
        path = root / f"fixture-{os.getpid()}.partial"
        path.write_text(json.dumps(ProcessTable().identity(os.getpid())))
        path.rename(path.with_suffix(".json"))
    record()
    if mode in ("detached", "early-exit", "retained-stdout"):
        pid = os.fork()
        if pid:
            if mode == "early-exit":
                os._exit(0)
            if mode == "retained-stdout":
                time.sleep(0.3)
                os._exit(0)
            time.sleep(10)
        else:
            signal.alarm(12)
            os.setsid()
            record()
            time.sleep(10)
    elif mode == "term-refusal":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(10)
    elif mode == "memory":
        allocation = bytearray(64 * MIB)
        for index in range(0, len(allocation), 4096):
            allocation[index] = 1
        time.sleep(10)
    elif mode == "output":
        print("x" * 8192, flush=True)
    elif mode == "cancel":
        time.sleep(0.3)
        os.kill(os.getppid(), signal.SIGTERM)
        time.sleep(10)
    elif mode in ("timeout", "measurement"):
        time.sleep(10)
    else:
        print("success", flush=True)


def check_case(mode, root):
    class BrokenMeasurement(ProcessTable):
        count = 0

        def memory(self, item):
            self.count += 1
            if self.count > 3:
                raise RuntimeError("injected missing footprint")
            return super().memory(item)

    if mode == "legacy-oracle":
        # Small red oracle for the old "leader exited => done" behavior. Its
        # detached fixture has a 12s alarm, not the old unbounded Swift hang.
        process = subprocess.Popen([sys.executable, __file__, "fixture", "early-exit", str(root)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        process.wait(timeout=3)
        time.sleep(0.1)
        table = ProcessTable()
        survivors = []
        for path in root.glob("fixture-*.json"):
            old = json.loads(path.read_text())
            live = table.identity(old["pid"])
            if live and live["unique"] == old["unique"] and live["status"] != 5:
                survivors.append(live)
                table.send(live, signal.SIGKILL)
        assert survivors, "Red oracle did not expose group-only cleanup gap"
        time.sleep(0.1)
        return {"case": mode, "passed": True, "legacyCleanupFailed": True, "survivorsBeforeRepairCleanup": survivors}
    if mode == "identity":
        table = ProcessTable()
        item = table.identity(os.getpid())
        item["unique"] += 1
        assert table.send(item, signal.SIGTERM) == "identity-mismatch"
        return {"case": mode, "passed": True, "replacementNotSignalled": True}
    original_pipe, original_close = os.pipe, os.close
    gate = []
    if mode == "gate-close":
        def pipe():
            pair = original_pipe()
            if not gate:
                gate.append(pair[1])
            return pair
        def close(fd):
            original_close(fd)
            if gate and fd == gate[0]:
                gate[0] = -1
                raise RuntimeError("injected failure after gate FD close")
        os.pipe, os.close = pipe, close
    try:
        result = run_command([sys.executable, __file__, "fixture", mode, str(root)], root,
                         {"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"}, root / "run.log",
                         0.6 if mode in ("timeout", "detached", "term-refusal") else 5,
                         maximum_log_bytes=4096, maximum_memory_bytes=48 * MIB if mode == "memory" else 256 * MIB,
                         maximum_processes=4, termination_grace=0.15,
                         table_factory=BrokenMeasurement if mode == "measurement" else ProcessTable)
    finally:
        os.pipe, os.close = original_pipe, original_close
    signal.setitimer(signal.ITIMER_REAL, 0)
    expected = {"success": None, "timeout": "timeout", "detached": "timeout",
                "early-exit": "launcher-exited-with-descendants", "retained-stdout": "launcher-exited-with-descendants",
                "term-refusal": "timeout", "memory": "memory-limit", "output": "output-limit",
                "measurement": "supervision-error", "gate-close": "supervision-error", "cancel": "cancelled"}[mode]
    assert result["stopReason"] == expected, result
    assert result["passed"] == (mode == "success"), result
    assert result["supervision"]["cleanupVerified"], result
    assert result["supervision"]["peakBytes"] < 256 * MIB, result
    if mode == "term-refusal":
        assert any(row["signal"] == 9 for row in result["supervision"]["signals"]), result
    return {"case": mode, "passed": True, "report": result}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "fixture":
        fixture(sys.argv[2], Path(sys.argv[3]))
        return
    if len(sys.argv) > 1 and sys.argv[1] == "case":
        print(json.dumps(check_case(sys.argv[2], Path(sys.argv[3]))), flush=True)
        return
    root = Path(tempfile.mkdtemp(prefix="ds-supervision-bootstrap.", dir="/private/tmp"))
    print(str(root), flush=True)
    results = []
    # Unrelated sentinel is outside every run's ownership; it has its own timer.
    sentinel = subprocess.Popen([sys.executable, "-c", "import signal,time; signal.alarm(180); time.sleep(170)"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for case in CASES:
            directory = root / case
            directory.mkdir()
            # Independent outer process watchdog, <=30s per pathological case.
            worker = subprocess.Popen([sys.executable, __file__, "case", case, str(directory)],
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                      env={"PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"})
            try:
                stdout, stderr = worker.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                worker.kill()  # Exact Popen handle; fixtures self-expire at 12s.
                stdout, stderr = worker.communicate(timeout=3)
                raise RuntimeError(f"Independent watchdog fired for {case}")
            if worker.returncode:
                raise RuntimeError(stderr.decode()[-6000:])
            result = json.loads(stdout)
            # Second observer checks persisted fixture identities, not runner's
            # claim or launcher return code. It never signals a discovered PID.
            table = ProcessTable()
            for path in directory.glob("fixture-*.json"):
                identity = json.loads(path.read_text())
                current = table.identity(identity["pid"])
                assert current is None or current["unique"] != identity["unique"] or current["status"] == 5
            assert sentinel.poll() is None, "Unrelated sentinel was terminated"
            results.append(result)
            print(case + ": passed", flush=True)
        (root / "result.json").write_text(json.dumps({"passed": True, "cases": results, "sentinelPreserved": True}, indent=2))
    finally:
        sentinel.terminate()
        sentinel.wait(timeout=3)


if __name__ == "__main__":
    main()
