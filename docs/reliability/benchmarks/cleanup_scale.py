#!/usr/bin/env python3
"""Remove archived synthetic runs. Preview first; confirm live handles stopped."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collection", type=Path, required=True)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirmed-stopped", action="store_true")
    args = parser.parse_args()
    collection = args.collection.resolve()
    if collection.parent.name != "RESEARCH-530" or collection.parent.parent.name != "evidence":
        parser.error("Not a RESEARCH-530 evidence collection")
    if (collection / "cleanup.json").exists():
        parser.error("This collection already has a cleanup record")
    records = json.loads((collection / "summary.json").read_text())["runs"]
    targets = []
    for record in records:
        expected_children = {"baseline", "fixture", "fixture.json", "owner-token", "fixture.log",
                             "fixture-supervision.json", "baseline.log", "baseline-supervision.json"}
        if record.get("phase", "baseline") in {"resume", "recovery"}:
            expected_children |= {"resume.log", "resume-supervision.json"}
        if record.get("phase") == "recovery":
            expected_children |= {"recovery.log", "recovery-supervision.json"}
        root = Path(record["root"])
        if (root.parent != Path("/private/tmp") or root.resolve() != root
                or not root.name.startswith("disk-steward-530-scale.") or not root.is_dir()):
            parser.error("Refusing noncanonical, missing or broad target")
        command = json.loads((root / "fixture-supervision.json").read_text())["command"]
        token = command[command.index("--token") + 1]
        if (root / "owner-token").read_text() != token:
            parser.error("Owner token mismatch")
        if {p.name for p in root.iterdir()} != expected_children:
            parser.error("Unexpected run-root contents; inspect before removing anything")
        if any(p.is_symlink() for p in root.iterdir()):
            parser.error("Unexpected symlink in run root")
        if not shutil.rmtree.avoids_symlink_attacks:
            parser.error("Safe directory removal unavailable")
        for name, digest in record["artifactSHA256"].items():
            archived = collection / record["label"] / name
            if hashlib.sha256(archived.read_bytes()).hexdigest() != digest:
                parser.error("Archived evidence hash mismatch")
            if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
                parser.error("Live evidence changed since collection")
        targets.append({"root": str(root), "label": record["label"], "fixture": record["fixture"]})
    if len({target["root"] for target in targets}) != len(targets):
        parser.error("Duplicate targets")
    print(json.dumps({"preview": targets}, sort_keys=True), flush=True)
    if not args.execute:
        return
    if not args.confirmed_stopped:
        parser.error("Confirm actual process handles are terminal; saved records alone are insufficient")
    removed = []
    for target in targets:
        shutil.rmtree(target["root"])
        removed.append(target)
        (collection / "cleanup.json").write_text(json.dumps({
            "removedAt": datetime.now(timezone.utc).isoformat(), "removed": removed,
            "recovery": "Synthetic fixtures can be regenerated; not moved to Trash.",
            "evidenceRetained": True,
        }, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"removedRunRoots": len(removed), "evidenceRetained": True}), flush=True)


if __name__ == "__main__":
    main()
