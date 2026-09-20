#!/usr/bin/env python3
"""Measure how object-detection rules classify candidate directories (RESEARCH-601).

Read-only. It never writes, moves or deletes anything in a measured corpus and
never runs a project's own tooling (no build, no install, no fetch). The only
subprocesses are `git check-ignore` and `git ls-files`, which read a repository
index and its ignore rules.

Rules, applied to the outermost candidate only:

  tracked     the owning repository tracks files inside it  -> never an artifact
  ignored     the owning repository ignores it              -> artifact
  self-marker a marker inside it identifies it (pyvenv.cfg) -> object
  content     its contents identify it (bytecode, packages)  -> object
  manifest    a project manifest beside it expects it        -> artifact
  unresolved  a known output name with no project evidence   -> not classified

Usage:
  measure_object_detection.py --roots PATH [PATH ...] --output DIR
  measure_object_detection.py --fixtures DIR        build the fixture corpus
  measure_object_detection.py --self-test DIR       build fixtures and check rules
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

# Directory name -> manifest files that make that name an expected output location.
# A name alone never classifies; it only makes a directory a candidate.
OUTPUT_NAMES: dict[str, tuple[str, ...]] = {
    "node_modules": ("package.json",),
    "target": ("Cargo.toml",),
    ".build": ("Package.swift",),
    "build": ("CMakeLists.txt", "build.gradle", "build.gradle.kts", "Makefile", "meson.build"),
    "dist": ("package.json", "pyproject.toml", "setup.py"),
    ".next": ("package.json",),
    ".nuxt": ("package.json",),
    ".turbo": ("package.json",),
    ".parcel-cache": ("package.json",),
    "out": ("package.json",),
    ".venv": ("pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"),
    "venv": ("pyproject.toml", "requirements.txt", "setup.py", "setup.cfg", "Pipfile"),
    "__pycache__": ("pyproject.toml", "requirements.txt", "setup.py", "setup.cfg"),
    ".tox": ("tox.ini", "pyproject.toml"),
    ".pytest_cache": ("pyproject.toml", "pytest.ini", "setup.cfg", "tox.ini"),
    ".mypy_cache": ("mypy.ini", "pyproject.toml", "setup.cfg"),
    ".gradle": ("build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"),
    "vendor": ("go.mod", "composer.json"),
    "Pods": ("Podfile",),
    "DerivedData": (),          # Xcode writes these; the marker is the enclosing project
    ".swiftpm": ("Package.swift",),
    "obj": ("*.csproj", "*.sln"),
    "bin": ("*.csproj", "*.sln"),
}
REPOSITORY_MARKER = ".git"

# Self-evidence: a marker inside the directory identifies it whatever it is
# named. This is what catches a virtualenv called "transcribe-env" and a cargo
# target directory outside any repository.
SELF_MARKERS = {
    "pyvenv.cfg": ("virtualenv", "it contains pyvenv.cfg, so it is a Python virtual environment"),
    "CACHEDIR.TAG": ("cache", "it is tagged as a cache directory (CACHEDIR.TAG)"),
}


def self_marker(directory: Path) -> tuple[str, str] | None:
    for name, (kind, reason) in SELF_MARKERS.items():
        if (directory / name).exists():
            return kind, reason
    return None


def looks_like_bytecode_cache(directory: Path) -> bool:
    """A __pycache__ holds compiled bytecode and nothing else."""
    try:
        entries = list(os.scandir(directory))
    except OSError:
        return False
    return bool(entries) and all(e.is_file() and e.name.endswith((".pyc", ".pyo")) for e in entries)


def looks_like_package_install(directory: Path) -> bool:
    """A node_modules holds installed packages, each with its own manifest."""
    try:
        for entry in os.scandir(directory):
            if entry.is_dir() and (Path(entry.path) / "package.json").exists():
                return True
            if entry.is_file() and entry.name in (".package-lock.json", ".yarn-state.yml", ".modules.yaml"):
                return True
    except OSError:
        return False
    return False


def manifest_present(parent: Path, names: tuple[str, ...]) -> str | None:
    for name in names:
        if name.startswith("*."):
            suffix = name[1:]
            try:
                for entry in os.scandir(parent):
                    if entry.name.endswith(suffix):
                        return entry.name
            except OSError:
                return None
        elif (parent / name).exists():
            return name
    return None


def nearest_repository(start: Path) -> Path | None:
    current = start
    while True:
        if (current / REPOSITORY_MARKER).is_dir():
            return current
        parent = current.parent
        if parent == current:
            return None
        current = parent


def find_candidates(roots: list[Path]) -> tuple[list[dict], dict]:
    """Walk the roots, recording the outermost candidate directories only."""
    candidates: list[dict] = []
    stats = Counter()
    for root in roots:
        for dirpath, dirnames, _ in os.walk(root, topdown=True, onerror=lambda _e: None):
            keep = []
            for name in dirnames:
                full = Path(dirpath) / name
                marker = self_marker(full)
                if name == REPOSITORY_MARKER:
                    candidates.append({"path": str(full), "name": name, "kind": "repository"})
                    stats["repository"] += 1
                elif marker is not None:
                    candidates.append({"path": str(full), "name": name, "kind": marker[0],
                                       "self_marker": marker[1]})
                    stats["self_marker_candidate"] += 1
                elif name in OUTPUT_NAMES:
                    candidates.append({"path": str(full), "name": name, "kind": "output"})
                    stats["output_candidate"] += 1
                else:
                    keep.append(name)
            dirnames[:] = keep
            stats["directories_walked"] += 1
    return candidates, dict(stats)


def git(args: list[str], cwd: Path, stdin: str | None = None, timeout: int = 180):
    return subprocess.run(["git", "-C", str(cwd), *args], input=stdin,
                          capture_output=True, text=True, timeout=timeout)


def classify(candidates: list[dict]) -> list[dict]:
    by_repo: dict[Path | None, list[dict]] = defaultdict(list)
    for candidate in candidates:
        repo = nearest_repository(Path(candidate["path"]).parent)
        candidate["repository"] = str(repo) if repo else None
        by_repo[repo].append(candidate)

    for repo, group in by_repo.items():
        outputs = [c for c in group if c["kind"] == "output"]
        for candidate in group:
            if candidate["kind"] in ("virtualenv", "cache"):
                candidate.update(rule="self-marker", classified=True, confidence="high",
                                 reason=candidate["self_marker"])
        if repo is None:
            ignored: set[str] = set()
        else:
            try:
                result = git(["check-ignore", "--stdin"], repo, "\n".join(c["path"] for c in outputs))
                ignored = {line for line in result.stdout.split("\n") if line}
            except Exception as error:  # a repository we cannot read decides nothing
                ignored = set()
                for candidate in outputs:
                    candidate["repository_error"] = type(error).__name__
        for candidate in outputs:
            if repo is not None and candidate["path"] not in ignored:
                try:
                    tracked = git(["ls-files", "--error-unmatch", "--", candidate["path"]], repo, timeout=60)
                    if tracked.returncode == 0 and tracked.stdout.strip():
                        candidate.update(rule="tracked", classified=False, confidence="high",
                                         reason="the owning repository tracks files inside it")
                        continue
                except Exception:
                    pass
            if candidate["path"] in ignored:
                candidate.update(rule="ignored", classified=True, confidence="high",
                                 reason="the owning repository ignores it")
                continue
            directory = Path(candidate["path"])
            if candidate["name"] == "__pycache__" and looks_like_bytecode_cache(directory):
                candidate.update(rule="content", classified=True, confidence="high",
                                 reason="it holds only compiled Python bytecode")
                continue
            if candidate["name"] == "node_modules" and looks_like_package_install(directory):
                candidate.update(rule="content", classified=True, confidence="high",
                                 reason="it holds installed packages with their own manifests")
                continue
            parent = directory.parent
            marker = manifest_present(parent, OUTPUT_NAMES[candidate["name"]])
            if marker:
                candidate.update(rule="manifest", classified=True, confidence="medium",
                                 reason=f"{marker} beside it expects this output location")
            else:
                candidate.update(rule="unresolved", classified=False, confidence="none",
                                 reason="a known output name with no project evidence")
    for candidate in candidates:
        if candidate["kind"] == "repository":
            candidate.update(rule="repository", classified=True, confidence="high",
                             reason="a repository is measured as one object and never offered for cleanup")
    return candidates


def measure(candidate_paths: list[dict]) -> None:
    for candidate in candidate_paths:
        files = size = 0
        for dirpath, _dirnames, filenames in os.walk(candidate["path"], onerror=lambda _e: None):
            for name in filenames:
                try:
                    size += os.lstat(os.path.join(dirpath, name)).st_size
                    files += 1
                except OSError:
                    pass
        candidate["file_count"] = files
        candidate["bytes"] = size


def report(candidates: list[dict], walk_stats: dict, roots: list[Path]) -> dict:
    rules = Counter(c["rule"] for c in candidates)
    classified = [c for c in candidates if c["classified"]]
    collapsed_files = sum(c.get("file_count", 0) for c in classified)
    collapsed_bytes = sum(c.get("bytes", 0) for c in classified)
    outputs = [c for c in candidates if c["kind"] == "output"]
    outside = [c for c in outputs if c["repository"] is None]
    unresolved = [c for c in outputs if c["rule"] == "unresolved"]
    return {
        "schema": "disk-steward-object-detection-measurement-v1",
        "roots": [str(r) for r in roots],
        "walk": walk_stats,
        "candidates": len(candidates),
        "by_rule": dict(rules),
        "classified_objects": len(classified),
        "collapsed_files": collapsed_files,
        "collapsed_bytes": collapsed_bytes,
        "outputs_outside_any_repository": len(outside),
        "outputs_outside_resolved_by_manifest": sum(1 for c in outside if c["rule"] == "manifest"),
        "outputs_outside_unresolved": sum(1 for c in outside if c["rule"] == "unresolved"),
        "name_only_would_classify": len(outputs),
        "name_only_false_positives": sum(1 for c in outputs if c["rule"] == "tracked"),
        "unresolved_total": len(unresolved),
        "unresolved_by_name": dict(Counter(c["name"] for c in unresolved)),
        "tracked_examples": [c["path"] for c in outputs if c["rule"] == "tracked"][:20],
        "unresolved_examples": [c["path"] for c in outputs if c["rule"] == "unresolved"][:20],
    }


FIXTURES = {
    # path -> (files to create, expected rule)
    "repo/.git": None,
    "repo/package.json": "{}",
    "repo/.gitignore": "node_modules/\ndist/\n",
    "repo/node_modules/left-pad/index.js": "module.exports = 0;\n",
    "repo/dist/bundle.js": "0;\n",
    "repo/scripts/build/deploy.sh": "#!/bin/sh\n",      # tracked lookalike
    "repo/src/main.js": "0;\n",
    "manifest-only/package.json": "{}",
    "manifest-only/node_modules/dep/index.js": "0;\n",
    "manifest-only/src/app.js": "0;\n",
    "orphan/build/output.o": "0",                        # no repository, no manifest
    "nested/package.json": "{}",
    "nested/node_modules/a/package.json": "{}",
    "nested/node_modules/a/node_modules/b/index.js": "0;\n",
    "odd-env/pyvenv.cfg": "home = /usr/bin\n",
    "odd-env/lib/python3.12/site-packages/dep/__pycache__/dep.cpython-312.pyc": "0",
    "loose/__pycache__/module.cpython-312.pyc": "0",
}
EXPECTED = {
    "repo/node_modules": "ignored",
    "repo/dist": "ignored",
    "repo/scripts/build": "tracked",
    "manifest-only/node_modules": "manifest",
    "orphan/build": "unresolved",
    "loose/__pycache__": "content",
    # content evidence outranks the parent manifest: this one holds installed packages
    "nested/node_modules": "content",
    "odd-env": "self-marker",
}


def build_fixtures(base: Path) -> Path:
    base.mkdir(parents=True, exist_ok=True)
    for relative, contents in FIXTURES.items():
        target = base / relative
        if contents is None:
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(contents)
    repo = base / "repo"
    if (repo / ".git").is_dir() and not (repo / ".git" / "HEAD").exists():
        (repo / ".git").rmdir()
    if not (repo / ".git" / "HEAD").exists():
        subprocess.run(["git", "init", "-q", str(repo)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(repo), "-c", "user.email=f@x", "-c", "user.name=f",
                    "commit", "-qm", "fixture"], check=True, capture_output=True)
    return base


def self_test(base: Path) -> int:
    build_fixtures(base)
    candidates, _ = find_candidates([base])
    classify(candidates)
    actual = {str(Path(c["path"]).relative_to(base)): c["rule"] for c in candidates}
    failures = []
    for relative, expected in EXPECTED.items():
        got = actual.get(relative)
        if got != expected:
            failures.append(f"{relative}: expected {expected}, got {got}")
    deep = [p for p in actual if p.count("node_modules") > 1]
    if deep:
        failures.append(f"nested candidates were not collapsed to the outermost match: {deep}")
    for line in failures:
        print("FAIL", line)
    print(f"self-test: {len(EXPECTED) - len(failures)}/{len(EXPECTED)} rules as expected")
    return 1 if failures else 0


def main() -> int:
    raise SystemExit("Corpus measurement admission closed by TASK-616: legacy enumeration and helper commands lack one bounded supervisor. See Scripts/Testing/SUPERVISION.md")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--roots", nargs="*", type=Path, default=[])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument("--self-test", type=Path)
    parser.add_argument("--measure-size", action="store_true", help="walk classified objects to size them")
    arguments = parser.parse_args()

    if arguments.self_test:
        return self_test(arguments.self_test)
    if arguments.fixtures:
        print(build_fixtures(arguments.fixtures))
        return 0
    if not arguments.roots or not arguments.output:
        parser.error("--roots and --output are required for a measurement run")

    roots = [Path(os.path.expanduser(str(r))).resolve() for r in arguments.roots]
    for root in roots:
        if not root.is_dir():
            parser.error(f"not a directory: {root}")
    candidates, walk_stats = find_candidates(roots)
    classify(candidates)
    if arguments.measure_size:
        measure([c for c in candidates if c["classified"]])
    summary = report(candidates, walk_stats, roots)
    arguments.output.mkdir(parents=True, exist_ok=True)
    (arguments.output / "measurement.json").write_text(json.dumps(summary, indent=1) + "\n")
    with (arguments.output / "candidates.jsonl").open("w") as stream:
        for candidate in sorted(candidates, key=lambda c: c["path"]):
            stream.write(json.dumps(candidate, sort_keys=True) + "\n")
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
