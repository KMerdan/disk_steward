# TASK-611 — Classifying projects and their output directories

Actor: `claude`, 2026-09-20. Candidate input `a6a717c7d0b4…` for the focused runs; the full verifier run is recorded below. Nothing was committed, installed or released while this was written, and no real project tree was modified: every run works on an isolated snapshot under `/private/tmp`.

## What was added

`Sources/DiskStewardCore/Monitoring/ObjectClassification.swift`

- `ClassifiedObject` carries the fields the contract requires of a detection result: path, kind (`artifact`, `cache`, `repository`), deciding rule, confidence, the sentence shown to a person, and the owning project with the marker that identified it. `isCleanupCandidate` is false for a repository, so the never-offer rule is a property of the type rather than a convention.
- `ObjectClassification` has three cases, which is the point: `object`, `source` for a directory that merely looks like output, and `unresolved` for a known name with no evidence. A caller cannot accidentally treat source or an unresolved candidate as an object.
- `ObjectClassifier.classify(directoryPath:repositoryPath:)` applies the rules in the order `RESEARCH-601` measured: tracked, self-marker, content, ignored, manifest, otherwise unresolved. Only `manifest` earns medium confidence; everything else is high.
- `RepositoryOracle` is a protocol whose answers are all optional. `nil` means the repository gave no verdict, so an unreadable repository never blocks the later rules and never decides by accident. `SilentRepositoryOracle` is the "no repository available" case.

`Sources/DiskStewardCore/Monitoring/GitRepositoryOracle.swift`

- Answers through `git check-ignore` and `git ls-files` only. It runs git with a clean environment (`GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, `GIT_CONFIG_NOSYSTEM=1`, no pager, null stdin), a bounded timeout, and no inherited configuration, so git cannot prompt, fetch or take a lock. A missing git, a timeout or a non-zero exit produces `nil`, never a guess. Answers are cached per repository and path.

The classifier is not yet wired into the scanner. That is `TASK-612`, and until then nothing in the product calls it.

## Proofs (AC-TASK-611-01)

| case | test | outcome |
|---|---|---|
| tracked source refused before every other rule | `testTrackedSourceIsRefusedBeforeEveryOtherRule` | a directory the repository tracks *and* ignores is `source`, never an object |
| marker identifies a directory whatever its name | `testMarkerInsideADirectoryIdentifiesItWhateverItIsNamed` | `transcribe-env` holding `pyvenv.cfg` is an artifact at high confidence |
| content decides with no project at all | `testContentEvidenceDecidesWithoutAnyProjectOrRepository` | bytecode-only `__pycache__` and a `node_modules` holding packages |
| content evidence is not assumed | `testMixedPythonDirectoryIsNotContentEvidence` | a `__pycache__` with a stray text file stays unresolved |
| ignored, then manifest, with the confidence each earns | `testIgnoredThenManifestDecideWhenContentDoesNot` | same directory: `ignored` high, `manifest` medium with its marker recorded |
| a name alone never classifies | `testAKnownNameWithoutEvidenceIsNeverGuessedAt` | an orphan `build` is unresolved with its reason |
| a repository is measured, never offered | `testARepositoryIsMeasuredButNeverACleanupCandidate` | kind `repository`, `isCleanupCandidate == false` |
| an unreadable repository decides nothing | `testAnUnreadableRepositoryDecidesNothingAndFallsThrough` | falls through to the manifest rule instead of failing closed or open |
| nearest repository, and none | `testNearestRepositoryIsFoundAndAbsentWhenThereIsNone` | found through nested packages; nil outside any repository |
| classification only reads | `testClassificationNeverWritesToTheExaminedTree` | a size and mtime snapshot of the tree is identical afterwards |

Ten tests, zero failures, in an isolated snapshot (`focused-green/`).

## Non-vacuity

| mutation | result |
|---|---|
| the tracked check is inverted, so tracked source is no longer refused first | `testTrackedSourceIsRefusedBeforeEveryOtherRule` fails (`tracked-mutation-red/`) |
| the self-marker rule never fires | `testMarkerInsideADirectoryIdentifiesItWhateverItIsNamed` fails (`marker-mutation-red/`) |

Both runs copied the candidate, changed only the named line in the copy, and left the worktree untouched (`repositoryUnchanged: true`).

## Limitations

- The unit tests script the repository's answers, so no `git` process runs in them. `GitRepositoryOracle` itself is exercised only by compilation here; its behaviour against a real repository was measured in `RESEARCH-601` through the same two commands, and the scanner integration in `TASK-612` will exercise it end to end.
- Content evidence reads one directory level, never a subtree, so a `node_modules` whose first entries are unusual may fall through to the ignored or manifest rule. That is a weaker rule deciding, never a wrong one.
- Classification answers about one directory. Choosing which directories to ask about, and collapsing nested matches to the outermost, belongs to the scanner in `TASK-612`.
- Detection covers the ecosystems the corpus contained. A project layout absent from that corpus resolves as unresolved, which the contract requires.
