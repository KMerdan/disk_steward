#!/usr/bin/env python3
"""Standalone real-time watchdog for the Disk Steward soak runs.

Runs outside any Claude session. Every 30 s it reads each soak root's cycle log
and supervisor progress, samples the test process with ps/lsof, scans for new
crash reports, and writes:
  watch.log    one line per tick per run (OK / WARN / CRIT with reasons)
  alerts.log   only WARN/CRIT lines (empty file means nothing went wrong)
  status.json  latest state, peaks, hourly RSS trend and alert counts
  <name>.archived when a run finishes and its evidence has been archived under
                 docs/reliability/evidence/TASK-572/soak-runs/<name>/
It exits when every run is finished and archived, or after --max-hours.
"""
import json, os, subprocess, sys, time, datetime, glob, shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
RUNS = [  # name, root, supervisor pattern, expected seconds
    ("soak-3h", Path("/private/tmp/disk-steward-572-soak.mzny29ey"), "supervise_soak.py --workspace /private/tmp/disk-steward-531-frontier", 10800),
    ("soak-overnight-8h", Path("/private/tmp/disk-steward-572-soak._2v0xc1b"), "supervise_soak.py --workspace /private/tmp/disk-steward-final-frontier", 28800),
]
MIB = 2 ** 20
RSS_WARN, RSS_STOP = 520 * MIB, 600 * MIB            # supervisor kills at 600 MiB
FAMILY_WARN, WAL_WARN = 2 * 1024 * MIB, 256 * MIB
FD_WARN, CYCLE_WARN, STALL_WARN = 64, 60.0, 600       # descriptors, seconds, seconds without a new cycle row
SLOPE_WARN = 20 * MIB                                  # RSS growth per hour over the trailing hour
DISK_WARN = 5 * 1024 * MIB
INTERVAL = 30
started = time.time()
crash_dir = Path.home() / "Library/Logs/DiagnosticReports"
seen_crashes = {p.name for p in crash_dir.glob("*.ips")} if crash_dir.exists() else set()
history = {name: [] for name, *_ in RUNS}            # (t, rss)
peaks = {name: {} for name, *_ in RUNS}
alerts = {name: {"WARN": 0, "CRIT": 0} for name, *_ in RUNS}
done = {name: False for name, *_ in RUNS}
last_cycle_seen = {name: (None, time.time()) for name, *_ in RUNS}

def now(): return datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
def log(line, alert=False):
    with open(HERE / "watch.log", "a") as f: f.write(line + "\n")
    if alert:
        with open(HERE / "alerts.log", "a") as f: f.write(line + "\n")
def sh(args):
    try: return subprocess.run(args, capture_output=True, text=True, timeout=20).stdout
    except Exception as e: return ""
def pgrep(pattern):
    out = sh(["/usr/bin/pgrep", "-f", pattern]); return [int(x) for x in out.split() if x.isdigit()]
def xctest_pid(root):
    for line in sh(["/bin/ps", "-axo", "pid=,command="]).splitlines():
        if "xctest -XCTest PerformanceTests.SoakBenchmarkTests" in line and str(root.parent) in line or ("xctest -XCTest PerformanceTests.SoakBenchmarkTests" in line and root.name in sh(["/bin/ps", "-o", "command=", "-E", "-p", line.split()[0]])):
            return int(line.split()[0])
    return None
def proc_sample(pid):
    out = sh(["/bin/ps", "-o", "rss=,%cpu=", "-p", str(pid)]).split()
    fds = len([l for l in sh(["/usr/sbin/lsof", "-p", str(pid)]).splitlines()[1:]]) if pid else None
    return (int(out[0]) * 1024 if out else None, float(out[1]) if len(out) > 1 else None, fds)
def last_rows(root):
    rows = []
    try:
        with open(root / "soak.log", errors="replace") as f:
            for line in f:
                if line.startswith("{") and '"kind": "cycle"' in line: rows.append(line)
    except FileNotFoundError: return None
    return json.loads(rows[-1]) if rows else None
def disk_free(path):
    st = os.statvfs(path); return st.f_bavail * st.f_frsize

def tick(name, root, pattern, expected):
    if done[name]: return
    reasons, level = [], "OK"
    def warn(r):
        nonlocal level; reasons.append(r); level = "WARN" if level == "OK" else level
    def crit(r):
        nonlocal level; reasons.append(r); level = "CRIT"
    result = root / "result.json"
    if result.exists():
        final = json.load(open(result)); status = final.get("status")
        if status not in ("completed", "external-stop"): crit(f"final status {status}: {str(final.get('failure') or final.get('error'))[:200]}")
        if final.get("mismatches") or final.get("totalMismatches"): crit(f"final mismatches {final.get('mismatches') or final.get('totalMismatches')}")
        try:
            subprocess.run([sys.executable, str(HERE / "archive_soak.py"), str(root), name], check=True, capture_output=True, text=True, timeout=300)
            (HERE / f"{name}.archived").write_text(now() + "\n"); reasons.append("archived under docs/reliability/evidence/TASK-572/soak-runs/" + name)
        except Exception as e: crit(f"archive failed: {e}")
        done[name] = True
        log(f"{now()} {name} FINISHED status={status} {level} {'; '.join(reasons)}", alert=level != "OK"); alerts[name][level] = alerts[name].get(level, 0) + (level != "OK")
        return
    row = last_rows(root)
    sup_alive = bool(pgrep(pattern))
    if not sup_alive:
        crit("supervisor process gone without result.json")
    if row is None:
        # fixture phase or not started
        log(f"{now()} {name} waiting: no cycle rows yet (fixture phase) supervisor={'alive' if sup_alive else 'GONE'}", alert=not sup_alive); return
    cycle = row.get("cycles"); prev_cycle, prev_t = last_cycle_seen[name]
    if cycle != prev_cycle: last_cycle_seen[name] = (cycle, time.time())
    elif time.time() - prev_t > STALL_WARN: warn(f"no new cycle for {int(time.time() - prev_t)} s")
    rss = row.get("peakInProcessRSSBytes") or 0; cur_rss = None
    pid = None
    for p in pgrep("xctest -XCTest PerformanceTests.SoakBenchmarkTests"):
        if str(root) in sh(["/bin/ps", "-o", "command=", "-E", "-p", str(p)]) or True: pid = p  # env not visible; pick any live soak xctest
    sample = proc_sample(pid) if pid else (None, None, None)
    cur_rss, cpu, fds = sample
    if row.get("mismatches") or row.get("mutationMismatches"): crit(f"mismatches {row.get('mismatches')}/{row.get('mutationMismatches')}")
    if row.get("error"): crit(f"error: {str(row.get('error'))[:200]}")
    if row.get("status") and row.get("status") not in ("running", "completed", "external-stop", ""): crit(f"status {row.get('status')}")
    if rss >= RSS_STOP * 0.98: crit(f"RSS {rss // MIB} MiB at the 600 MiB stop threshold")
    elif rss >= RSS_WARN: warn(f"RSS {rss // MIB} MiB above {RSS_WARN // MIB} MiB")
    fam = row.get("databaseFamilyBytes") or 0; wal = row.get("peakSampledWALBytes") or 0
    if fam >= FAMILY_WARN: warn(f"database family {fam // MIB} MiB")
    if wal >= WAL_WARN: warn(f"WAL peak {wal // MIB} MiB")
    fdc = row.get("openDescriptors") or fds or 0
    if fdc >= FD_WARN: warn(f"descriptors {fdc}")
    if (row.get("maxCycleSeconds") or 0) >= CYCLE_WARN: warn(f"max cycle {row.get('maxCycleSeconds'):.0f} s")
    if row.get("forcedEvictions"): warn(f"forced evictions {row.get('forcedEvictions')}")
    if row.get("admission") not in (None, "available"): warn(f"admission {row.get('admission')}")
    free = disk_free("/private/tmp")
    if free < DISK_WARN: crit(f"disk free {free // MIB} MiB on /private/tmp")
    if crash_dir.exists():
        for p in crash_dir.glob("*.ips"):
            if p.name not in seen_crashes:
                seen_crashes.add(p.name)
                if any(k in p.name for k in ("xctest", "DiskSteward", "disk-witness", "Disk Steward")): crit(f"new crash report {p.name}")
    # trailing-hour RSS slope
    h = history[name]; h.append((time.time(), rss)); cutoff = time.time() - 3600
    while h and h[0][0] < cutoff: h.pop(0)
    slope = None
    if len(h) >= 10 and h[-1][0] - h[0][0] > 1800:
        n = len(h); mt = sum(t for t, _ in h) / n; mr = sum(r for _, r in h) / n
        den = sum((t - mt) ** 2 for t, _ in h); slope = (sum((t - mt) * (r - mr) for t, r in h) / den) * 3600 if den else 0
        if slope > SLOPE_WARN: warn(f"RSS growing {slope / MIB:.1f} MiB/h over the trailing hour")
    pk = peaks[name]
    for k in ("peakInProcessRSSBytes", "databaseFamilyBytes", "peakSampledWALBytes", "openDescriptors", "peakCPUPercent", "maxCycleSeconds", "cycles", "elapsedSeconds"):
        v = row.get(k)
        if isinstance(v, (int, float)): pk[k] = max(pk.get(k, 0), v)
    if level != "OK": alerts[name][level] += 1
    log(f"{now()} {name} cycle={cycle} elapsed={int(row.get('elapsedSeconds') or 0)}s/{expected}s rss={rss // MIB}MiB live_rss={(cur_rss or 0) // MIB}MiB cpu={cpu} fds={fdc} family={fam // MIB}MiB wal={wal // MIB}MiB mismatches={row.get('mismatches')} evictions={row.get('forcedEvictions')} exports={row.get('exports')}/{row.get('exportRefusals')} supervisor={'alive' if sup_alive else 'GONE'} {level}{(' ' + '; '.join(reasons)) if reasons else ''}", alert=level != "OK")
    status = {"updated": now(), "watchdog_started": datetime.datetime.fromtimestamp(started, datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'), "runs": {}}
    return slope

def write_status(slopes):
    status = {"schema": "disk-steward-soak-watch-v1", "updated": now(), "watchdog_pid": os.getpid(), "runs": {}}
    for name, root, pattern, expected in RUNS:
        row = last_rows(root) or {}
        status["runs"][name] = {"root": str(root), "expected_seconds": expected, "finished": done[name], "archived": (HERE / f"{name}.archived").exists(),
                                "cycles": row.get("cycles"), "elapsed_seconds": row.get("elapsedSeconds"), "mismatches": row.get("mismatches"), "peaks": peaks[name],
                                "rss_slope_bytes_per_hour": slopes.get(name), "alerts": alerts[name], "supervisor_alive": bool(pgrep(pattern))}
    tmp = HERE / "status.json.tmp"; tmp.write_text(json.dumps(status, indent=1) + "\n"); os.replace(tmp, HERE / "status.json")

def main():
    max_hours = float(sys.argv[1]) if len(sys.argv) > 1 else 14.0
    log(f"{now()} watchdog started pid={os.getpid()} runs={[n for n, *_ in RUNS]} interval={INTERVAL}s max_hours={max_hours}")
    slopes = {}
    while time.time() - started < max_hours * 3600:
        for name, root, pattern, expected in RUNS:
            try: slopes[name] = tick(name, root, pattern, expected)
            except Exception as e: log(f"{now()} {name} WATCHDOG-ERROR {type(e).__name__}: {e}", alert=True)
        try: write_status(slopes)
        except Exception as e: log(f"{now()} status.json WATCHDOG-ERROR {e}", alert=True)
        if all(done.values()):
            log(f"{now()} watchdog finished: every run archived; alerts={alerts}"); (HERE / "watch-complete").write_text(now() + "\n"); return 0
        time.sleep(INTERVAL)
    log(f"{now()} watchdog reached max_hours; runs not all finished: {[n for n, d in done.items() if not d]}", alert=True); return 2

if __name__ == "__main__":
    sys.exit(main())
