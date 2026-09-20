"""Bounded macOS supervision for trusted, snapshot-isolated verification.

Ownership uses kernel birth IDs/original parent IDs, plus a random inherited
run marker for short-lived intermediate parents. Never use a process name,
path, or process group as authority to signal. This is NOT a hostile-code
sandbox: delegation to launchd/XPC or intentionally stripped lineage is not
supported. See SUPERVISION.md for limits and the required bootstrap.
"""
import ctypes as C
import errno
import hashlib
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time
import uuid

MIB = 1024 ** 2
MARKER = "DISK_STEWARD_VERIFICATION_RUN"


class SupervisorCancelled(BaseException):
    """Not InterruptedError: Python selectors may swallow that as syscall EINTR."""


class BSDInfo(C.Structure):
    _fields_ = [(name, C.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid",
        "rgid", "svuid", "svgid", "reserved")] + [
        ("comm", C.c_char * 16), ("name", C.c_char * 32)] + [
        (name, C.c_uint32) for name in ("files", "pgid", "jobc", "tty", "tpgid", "nice")
    ] + [("start_sec", C.c_uint64), ("start_usec", C.c_uint64)]


class BirthInfo(C.Structure):
    # Apple XNU proc_info_private.h: PROC_PIDUNIQIDENTIFIERINFO (17).
    _fields_ = [("uuid", C.c_ubyte * 16), ("unique", C.c_uint64),
                ("parent", C.c_uint64), ("version", C.c_int32),
                ("parent_version", C.c_int32), ("reserved", C.c_uint64 * 2)]


class Usage(C.Structure):
    _fields_ = [("uuid", C.c_ubyte * 16)] + [(name, C.c_uint64) for name in (
        "user", "system", "wakeups", "interrupts", "pageins", "wired", "rss",
        "footprint", "started", "exited")]


class ProcessTable:
    def __init__(self):
        if sys.platform != "darwin":
            raise RuntimeError("Supervision requires macOS libproc; no RSS-only fallback")
        self.lib = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.sys = C.CDLL(None, use_errno=True)
        if (C.sizeof(BSDInfo), C.sizeof(BirthInfo), C.sizeof(Usage)) != (136, 56, 96):
            raise RuntimeError("Unexpected process ABI")
        own = self.identity(os.getpid())
        if own is None or own["uid"] != os.getuid():
            raise RuntimeError("Process identity preflight failed")
        self.memory(own)

    def identity(self, pid):
        bsd, birth, after = BSDInfo(), BirthInfo(), BirthInfo()
        for flavor, value in ((17, birth), (3, bsd), (17, after)):
            C.set_errno(0)
            count = self.lib.proc_pidinfo(pid, flavor, 0, C.byref(value), C.sizeof(value))
            if count != C.sizeof(value):
                if C.get_errno() in (errno.ESRCH, errno.ENOENT):
                    return None
                raise OSError(C.get_errno(), f"Cannot establish process identity for {pid}")
        if birth.unique != after.unique:
            raise RuntimeError(f"Process identity changed during inspection of {pid}")
        return {"pid": pid, "unique": birth.unique, "parent": birth.parent,
                "uid": bsd.uid, "status": bsd.status, "pgid": bsd.pgid,
                "start": bsd.start_sec + bsd.start_usec / 1_000_000}

    def snapshot(self):
        # Bounded, same-UID inventory; no process arguments in logs/evidence.
        pids = (C.c_int * 16384)()
        count = self.lib.proc_listpids(4, os.getuid(), pids, C.sizeof(pids))
        if count <= 0 or count >= C.sizeof(pids):
            raise RuntimeError("Process inventory unavailable or exceeds budget")
        result = {}
        for pid in pids[:count // C.sizeof(C.c_int)]:
            if pid:
                identity = self.identity(pid)
                if identity:
                    result[identity["unique"]] = identity
        return result

    def marked(self, item, marker):
        # Only new, same-user candidates are inspected. Never retain or print
        # argv/environment: return one marker comparison and discard the buffer.
        if item["status"] == 5:
            return False
        mib = (C.c_int * 3)(1, 49, item["pid"])  # CTL_KERN/KERN_PROCARGS2
        data, size = C.create_string_buffer(MIB), C.c_size_t(MIB)
        if self.sys.sysctl(mib, 3, data, C.byref(size), None, 0) != 0:
            now = self.identity(item["pid"])
            if now is None or now["unique"] != item["unique"] or now["status"] == 5:
                return False
            raise RuntimeError(f"Cannot classify new process {item['pid']} (errno {C.get_errno()})")
        matches = (MARKER + "=" + marker).encode() in data.raw[:size.value].split(b"\0")
        after = self.identity(item["pid"])
        if after is None or after["unique"] != item["unique"]:
            return False
        return matches

    def memory(self, item):
        usage = Usage()
        if self.lib.proc_pid_rusage(item["pid"], 0, C.byref(usage)) != 0:
            now = self.identity(item["pid"])
            if now is None or now["unique"] != item["unique"] or now["status"] == 5:
                return 0
            raise RuntimeError(f"Footprint measurement failed for {item['pid']}")
        now = self.identity(item["pid"])
        if now is None or now["unique"] != item["unique"]:
            return 0
        return usage.footprint

    def send(self, item, signum):
        now = self.identity(item["pid"])
        if now is None or now["status"] == 5:
            return "exited"
        if now["unique"] != item["unique"] or now["uid"] != os.getuid():
            return "identity-mismatch"
        try:
            os.kill(item["pid"], signum)
            return "sent"
        except ProcessLookupError:
            return "exited"


class Family:
    def __init__(self, table, root, marker, started, baseline=()):
        self.table, self.marker = table, marker
        self.owned = {root["unique"]: root}
        self.root = root["unique"]
        self.unrelated = set(baseline) - {self.root}

    def discover(self):
        snapshot = self.table.snapshot()
        self._extend_lineage(snapshot)
        # A birth chain rooted in a pre-run process cannot belong to this gated
        # launch. Do not read its environment or let unrelated system activity
        # masquerade as missing owned-process telemetry.
        while True:
            additions = {key for key, value in snapshot.items()
                         if key not in self.owned and key not in self.unrelated
                         and value["parent"] in self.unrelated}
            if not additions:
                break
            self.unrelated.update(additions)
        for item in snapshot.values():
            if item["unique"] in self.owned or item["unique"] in self.unrelated:
                continue
            if self.table.marked(item, self.marker):
                self.owned[item["unique"]] = item
        self._extend_lineage(snapshot)
        if len(self.owned) > 4096 or len(self.unrelated) > 16384:
            raise RuntimeError("Owned identity ledger exceeds budget")
        return [value for key, value in snapshot.items()
                if key in self.owned and value["status"] != 5]

    def _extend_lineage(self, snapshot):
        # Original parent IDs survive setsid and reparenting; fixed point also
        # handles an environment-scrubbing child while its ancestor is known.
        while True:
            additions = {key: value for key, value in snapshot.items()
                         if key not in self.owned and value["parent"] in self.owned}
            if not additions:
                break
            self.owned.update(additions)


def run_command(command, cwd, environment, log, seconds, maximum_log_bytes=8 * MIB,
                stdin_path=None, maximum_memory_bytes=2 * 1024 * MIB,
                termination_grace=1.0, maximum_processes=64, table_factory=ProcessTable):
    """Return a failed report unless both command and identity-bound cleanup pass."""
    if (not math.isfinite(seconds) or not 0 < seconds <= 3600 or
            not 0 < maximum_log_bytes <= 64 * MIB or
            not 0 < maximum_memory_bytes <= 8 * 1024 * MIB or
            not 0 < termination_grace <= 5 or not 0 < maximum_processes <= 128):
        raise ValueError("Invalid finite supervision budgets")
    log = Path(log)
    started, wall_start = time.monotonic(), time.time()
    reason, error, child, family = None, None, None, None
    peak, retained, signals, remaining, cleanup_errors = 0, 0, [], [], []
    marker = str(uuid.uuid4())
    table = table_factory()  # Fail BEFORE launch when inspection is unavailable.
    baseline = table.snapshot()
    selector = None
    old_handlers = {}
    cancellation = []

    def cancel(signum, _frame):
        # Do not asynchronously unwind an FD close or launch bookkeeping.
        # The bounded polling loop observes this flag; no selector can swallow it.
        if not cancellation:
            cancellation.append(signum)

    def close_descriptor(descriptor):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError as exc:
                if exc.errno != errno.EBADF:
                    cleanup_errors.append(str(exc))

    def close_stream(stream):
        if stream is not None:
            try:
                stream.close()
            except Exception as exc:
                cleanup_errors.append(str(exc))

    # A gate establishes the root identity before the actual tool can fork.
    gate_read = gate_write = source = None
    gate = "import os,sys; fd=int(sys.argv[1]); ok=os.read(fd,1); os.close(fd); os.execvpe(sys.argv[2],sys.argv[2:],os.environ) if ok==b'G' else sys.exit(125)"
    with log.open("xb") as output:
        try:
            selector = selectors.DefaultSelector()
            gate_read, gate_write = os.pipe()
            source = stdin_path.open("rb") if stdin_path else None
            for sig in (signal.SIGTERM, signal.SIGINT):
                old_handlers[sig] = signal.signal(sig, cancel)
            if cancellation:
                raise SupervisorCancelled("Cancelled before launch")
            child = subprocess.Popen([sys.executable, "-c", gate, str(gate_read), *command],
                                     cwd=cwd, env={**environment, MARKER: marker},
                                     stdin=source or subprocess.DEVNULL,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     pass_fds=(gate_read,), start_new_session=True)
            root = table.identity(child.pid)
            if root is None:
                raise RuntimeError("Launch gate exited before identity registration")
            family = Family(table, root, marker, wall_start, baseline)
            if cancellation:
                raise SupervisorCancelled("Cancelled before execution gate")
            os.write(gate_write, b"G")
            os.close(gate_write)
            gate_write = None
            os.set_blocking(child.stdout.fileno(), False)
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                alive = family.discover()
                total = sum(table.memory(item) for item in alive)
                peak = max(peak, total)
                if cancellation:
                    reason = "cancelled"
                elif time.monotonic() - started >= seconds:
                    reason = "timeout"
                elif total > maximum_memory_bytes:
                    reason = "memory-limit"
                elif len(alive) > maximum_processes:
                    reason = "process-limit"
                if reason:
                    break
                for key, _ in selector.select(timeout=0.025):
                    data = os.read(key.fd, 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    available = maximum_log_bytes - retained
                    output.write(data[:available])
                    retained += min(len(data), available)
                    if len(data) > available:
                        reason = "output-limit"
                if reason:
                    break
                if child.poll() is not None:
                    alive = family.discover()
                    if alive:
                        reason = "launcher-exited-with-descendants"
                        break
                    if not selector.get_map():
                        break
        except BaseException as exc:
            reason = "cancelled" if isinstance(exc, (SupervisorCancelled, InterruptedError, KeyboardInterrupt)) else "supervision-error"
            error = f"{type(exc).__name__}: {exc}"
        finally:
            # Once cleanup begins, a second cancellation cannot interrupt it.
            for sig in old_handlers:
                signal.signal(sig, signal.SIG_IGN)
            close_descriptor(gate_write)  # A still-gated child exits without exec.
            close_descriptor(gate_read)
            close_stream(source)
            if family:
                # Keep discovering while stopping so newly forked descendants
                # are included. Use identities, never killpg/pkill.
                deadline = time.monotonic() + termination_grace + 2
                force_at = time.monotonic() + termination_grace
                quiet = 0
                while time.monotonic() < deadline:
                    try:
                        alive = family.discover()
                    except Exception as exc:
                        cleanup_errors.append(str(exc))
                        alive = list(family.owned.values())
                    for item in alive:
                        try:
                            sig = signal.SIGKILL if time.monotonic() >= force_at else signal.SIGTERM
                            sent = table.send(item, sig)
                            record = {"pid": item["pid"], "unique": item["unique"], "signal": int(sig), "result": sent}
                            if record not in signals:
                                signals.append(record)
                            if sent == "identity-mismatch":
                                cleanup_errors.append("PID identity changed; replacement not signalled")
                        except Exception as exc:
                            cleanup_errors.append(str(exc))
                    child.poll()
                    quiet = quiet + 1 if not alive else 0
                    if quiet >= 3:
                        break
                    time.sleep(0.025)
                try:
                    # Independent fresh inventory, not just the launcher's exit.
                    remaining = family.discover()
                except Exception as exc:
                    cleanup_errors.append(str(exc))
                    remaining = list(family.owned.values())
            if child:
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    cleanup_errors.append("Launcher exit could not be verified")
                close_stream(child.stdout)
            close_stream(selector)
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
    clean = not remaining and not cleanup_errors and child is not None and child.returncode is not None
    return {"command": command, "exitCode": child.returncode if child else None,
            "stopReason": reason, "error": error, "seconds": time.monotonic() - started,
            "log": log.name, "logSHA256": hashlib.sha256(log.read_bytes()).hexdigest(),
            "passed": clean and child.returncode == 0 and reason is None,
            "supervision": {"schema": "process-supervision-v1", "metric": "aggregate-ri_phys_footprint",
                "peakBytes": peak, "memoryLimitBytes": maximum_memory_bytes, "wallLimitSeconds": seconds,
                "outputLimitBytes": maximum_log_bytes, "retainedOutputBytes": retained,
                "processLimit": maximum_processes, "terminationGraceSeconds": termination_grace,
                "pollSeconds": 0.025, "cleanupVerified": clean, "remaining": remaining,
                "cleanupErrors": sorted(set(cleanup_errors)), "signals": signals,
                "identities": list(family.owned.values()) if family else [],
                "limitations": ["Trusted direct process trees only; no launchd/XPC delegation or deliberate lineage hiding.",
                    "Sampled footprint can overshoot between polls; it is not a kernel hard quota.",
                    "Identity is rechecked before each PID signal; macOS exposes no public atomic PID+birth-ID kill."]}}
