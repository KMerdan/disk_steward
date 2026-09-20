# RESEARCH-601 — Which rule decides that a directory is an object

Actor: `claude`, 2026-09-20. Read-only measurement: nothing in the corpus was written, moved or deleted, and no project tooling was executed. The only subprocesses are `git check-ignore` and `git ls-files`. Tool: `Scripts/Testing/measure_object_detection.py`, which also builds the fixture corpus and self-tests the rules.

## The rules, in the order they decide

| rule | evidence | outcome | confidence |
|---|---|---|---|
| `tracked` | the owning repository tracks files inside it | **never an object**, it is source | high |
| `self-marker` | a marker inside it identifies it: `pyvenv.cfg`, `CACHEDIR.TAG` | object | high |
| `content` | its contents identify it: only compiled bytecode; installed packages with their own manifests | object | high |
| `ignored` | the owning repository ignores it | object | high |
| `manifest` | a project manifest beside it expects that output location | object | medium |
| `unresolved` | a known output name with no project evidence | **not classified** | none |
| `repository` | a `.git` directory | object, measured, never a cleanup candidate | high |

Only the outermost candidate becomes an object; nothing inside one is examined again.

## Result on the corpus

Roots: `~/Documents/Codex`, `~/Downloads`, `~/localGit`. 47,536 directories walked.

| rule | first rules | with self-marker and content evidence |
|---|---|---|
| ignored | 1,098 | 986 |
| self-marker | n/a | 142 |
| content | n/a | 49 |
| manifest | 28 | 3 |
| repository | 338 | 338 |
| tracked (refused) | 30 | 29 |
| **unresolved** | **1,448** | **27** |

Classified objects: 1,518, collapsing 929,727 files and 70.2 GB.

## What the evidence decided

**A name never classifies.** 29 directories with output names are tracked source, including `~/localGit/echo/scripts/build`, `~/localGit/disk_steward/.swiftpm` and `~/localGit/causal-belief-system/site/docs/vendor`. Name matching alone would have offered every one of them for deletion. The tracked check must run before any other rule.

**Git decides where it applies, and it does not apply widely enough.** 1,468 of 2,615 output candidates sit outside any repository. Ignore rules resolved 986 of them and nothing else, so a fallback was required.

**The fallback is self-evidence, not a longer name list.** The first draft used a parent manifest, which resolved only 20 candidates and left 1,448 unresolved. 1,417 of those were `__pycache__` directories inside a virtual environment named `transcribe-env`, a name no table would contain. A directory holding `pyvenv.cfg` is a virtual environment whatever it is called, and as the outermost object it absorbs everything beneath it. `CACHEDIR.TAG` is a published convention that cargo and others already write. Content evidence covers the rest: a `__pycache__` holding only bytecode, a `node_modules` holding packages with their own manifests. Together these left 27 unresolved.

**The 27 that remain stay unclassified**, and that is the correct outcome: `bin` (12), `build` (10), `dist` (3), `target` (1), `vendor` (1) with no repository, no marker and no manifest. They must never be guessed at. A later task may offer the user an explicit override.

## Fixture corpus

`measure_object_detection.py --self-test <dir>` builds a repository with ignored and tracked lookalikes, a manifest-only project, nested `node_modules`, a virtual environment with a non-standard name, a stray `__pycache__` and an orphan `build`, then asserts the deciding rule for all eight. It passes 8 of 8 and is the regression basis for TASK-611.

## Limitations

- One maintainer machine on macOS. Rule coverage elsewhere is unmeasured; the shape of the finding, that git decides less than half, may differ on other corpora.
- `git ls-files` and `git check-ignore` read the index and ignore rules of a repository as it is on disk; a repository in an unusual state decides nothing and its candidates fall through to the later rules.
- Sizes come from `lstat` sums, not allocated blocks, so they are logical bytes and slightly under what the volume reports.
- Classification here is measurement only. No product code consumes these rules yet; that is TASK-611.
