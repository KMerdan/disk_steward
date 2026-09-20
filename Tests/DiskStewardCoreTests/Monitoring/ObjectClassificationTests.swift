@testable import DiskStewardCore
import Foundation
import XCTest

/// The rules and their order come from the corpus measured in RESEARCH-601:
/// docs/reliability/evidence/RESEARCH-601/detection-rules.md.
final class ObjectClassificationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds611-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTrackedSourceIsRefusedBeforeEveryOtherRule() throws {
        // The corpus produced 29 of these, including a committed scripts/build.
        let directory = try makeDirectory("project/scripts/build")
        try write("project/package.json", "{}")
        try write("project/scripts/build/deploy.sh", "#!/bin/sh\n")
        let oracle = ScriptedOracle(tracked: [directory.path: true], ignored: [directory.path: true])
        let classifier = ObjectClassifier(oracle: oracle)

        let classification = classifier.classify(directoryPath: directory.path, repositoryPath: root.appendingPathComponent("project").path)

        guard case let .source(path, reason) = classification else {
            return XCTFail("tracked source must never be an object: \(classification)")
        }
        XCTAssertEqual(path, directory.path)
        XCTAssertTrue(reason.contains("tracks files inside it"), reason)
        XCTAssertNil(classification.object)
    }

    func testMarkerInsideADirectoryIdentifiesItWhateverItIsNamed() throws {
        // The corpus hid 1,417 __pycache__ directories inside "transcribe-env".
        let directory = try makeDirectory("transcribe-env")
        try write("transcribe-env/pyvenv.cfg", "home = /usr/bin\n")

        let classification = ObjectClassifier().classify(directoryPath: directory.path)

        let object = try XCTUnwrap(classification.object)
        XCTAssertEqual(object.rule, .selfMarker)
        XCTAssertEqual(object.kind, .artifact)
        XCTAssertEqual(object.confidence, .high)
        XCTAssertTrue(object.reason.contains("pyvenv.cfg"), object.reason)
    }

    func testContentEvidenceDecidesWithoutAnyProjectOrRepository() throws {
        let bytecode = try makeDirectory("stray/__pycache__")
        try write("stray/__pycache__/module.cpython-312.pyc", "0")
        let packages = try makeDirectory("work/node_modules")
        try makeDirectory("work/node_modules/left-pad")
        try write("work/node_modules/left-pad/package.json", "{}")
        let classifier = ObjectClassifier()

        let cache = try XCTUnwrap(classifier.classify(directoryPath: bytecode.path).object)
        XCTAssertEqual(cache.rule, .content)
        XCTAssertTrue(cache.reason.contains("compiled Python bytecode"), cache.reason)

        let installed = try XCTUnwrap(classifier.classify(directoryPath: packages.path).object)
        XCTAssertEqual(installed.rule, .content)
        XCTAssertTrue(installed.reason.contains("installed packages"), installed.reason)
    }

    func testMixedPythonDirectoryIsNotContentEvidence() throws {
        // A __pycache__ holding anything but bytecode is not self-evident.
        let directory = try makeDirectory("odd/__pycache__")
        try write("odd/__pycache__/module.cpython-312.pyc", "0")
        try write("odd/__pycache__/notes.txt", "keep me")

        let classification = ObjectClassifier().classify(directoryPath: directory.path)

        guard case let .unresolved(candidate) = classification else {
            return XCTFail("mixed contents must not classify: \(classification)")
        }
        XCTAssertEqual(candidate.name, "__pycache__")
    }

    func testIgnoredThenManifestDecideWhenContentDoesNot() throws {
        let ignoredDirectory = try makeDirectory("repo/target")
        try write("repo/Cargo.toml", "[package]\n")
        let oracle = ScriptedOracle(tracked: [:], ignored: [ignoredDirectory.path: true])
        let repository = root.appendingPathComponent("repo").path

        let ignored = try XCTUnwrap(ObjectClassifier(oracle: oracle)
            .classify(directoryPath: ignoredDirectory.path, repositoryPath: repository).object)
        XCTAssertEqual(ignored.rule, .ignored)
        XCTAssertEqual(ignored.confidence, .high)

        // Same directory, a repository that says nothing: the manifest decides
        // and earns only medium confidence.
        let byManifest = try XCTUnwrap(ObjectClassifier(oracle: SilentRepositoryOracle())
            .classify(directoryPath: ignoredDirectory.path, repositoryPath: repository).object)
        XCTAssertEqual(byManifest.rule, .manifest)
        XCTAssertEqual(byManifest.confidence, .medium)
        XCTAssertEqual(byManifest.owningProjectMarker, "Cargo.toml")
    }

    func testAKnownNameWithoutEvidenceIsNeverGuessedAt() throws {
        let directory = try makeDirectory("orphan/build")
        try write("orphan/build/output.o", "0")

        let classification = ObjectClassifier().classify(directoryPath: directory.path)

        guard case let .unresolved(candidate) = classification else {
            return XCTFail("a name alone must never classify: \(classification)")
        }
        XCTAssertEqual(candidate.name, "build")
        XCTAssertTrue(candidate.reason.contains("no project evidence"), candidate.reason)
    }

    func testARepositoryIsMeasuredButNeverACleanupCandidate() throws {
        let directory = try makeDirectory("repo/.git")

        let object = try XCTUnwrap(ObjectClassifier().classify(directoryPath: directory.path).object)

        XCTAssertEqual(object.kind, .repository)
        XCTAssertEqual(object.rule, .repository)
        XCTAssertFalse(object.isCleanupCandidate)
        XCTAssertTrue(object.reason.contains("never offered"), object.reason)
    }

    func testAnUnreadableRepositoryDecidesNothingAndFallsThrough() throws {
        let directory = try makeDirectory("repo/node_modules")
        try write("repo/package.json", "{}")
        // Both answers nil: the repository exists but cannot answer.
        let classifier = ObjectClassifier(oracle: SilentRepositoryOracle())

        let object = try XCTUnwrap(classifier
            .classify(directoryPath: directory.path, repositoryPath: root.appendingPathComponent("repo").path).object)

        XCTAssertEqual(object.rule, .manifest, "an unreadable repository must not block later evidence")
    }

    func testNearestRepositoryIsFoundAndAbsentWhenThereIsNone() throws {
        let nested = try makeDirectory("repo/packages/app/node_modules")
        try makeDirectory("repo/.git")
        let classifier = ObjectClassifier()

        // The walk standardizes, so /private/tmp is reported as /tmp.
        XCTAssertEqual(classifier.repositoryPath(for: nested.path),
                       root.appendingPathComponent("repo").standardizedFileURL.path)
        let orphan = try makeDirectory("elsewhere/node_modules")
        XCTAssertNil(classifier.repositoryPath(for: orphan.path))
    }

    // A relative path has no ancestors to walk: deletingLastPathComponent
    // prepends ".." forever instead of reaching a fixed point, which hung a
    // scan until this was bounded.
    func testARelativeOrOddPathDecidesNothingInsteadOfWalkingForever() throws {
        let classifier = ObjectClassifier()
        for path in ["", "relative/node_modules", "..", "./x"] {
            let started = Date()
            XCTAssertNil(classifier.repositoryPath(for: path), path)
            XCTAssertEqual(classifier.ancestors(of: path), [], path)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1, "\(path) must not walk forever")
        }
    }

    func testAncestorsRunOutermostLastAndStopAtTheRoot() throws {
        let nested = try makeDirectory("a/b/c")
        let chain = ObjectClassifier().ancestors(of: nested.path)

        XCTAssertEqual(chain.first, nested.standardizedFileURL.path)
        XCTAssertEqual(chain.last, "/")
        XCTAssertLessThan(chain.count, ObjectClassifier.maximumAncestorDepth)
        XCTAssertEqual(Set(chain).count, chain.count, "each ancestor appears once")
    }

    func testClassificationNeverWritesToTheExaminedTree() throws {
        let directory = try makeDirectory("repo/node_modules")
        try write("repo/package.json", "{}")
        try makeDirectory("repo/node_modules/dep")
        try write("repo/node_modules/dep/package.json", "{}")
        let before = try snapshot(of: root)

        _ = ObjectClassifier().classify(directoryPath: directory.path,
                                        repositoryPath: root.appendingPathComponent("repo").path)

        XCTAssertEqual(try snapshot(of: root), before, "classification must only read")
    }

    // MARK: - helpers

    @discardableResult
    private func makeDirectory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func snapshot(of directory: URL) throws -> [String] {
        var entries: [String] = []
        let enumerator = FileManager.default.enumerator(atPath: directory.path)
        while let relative = enumerator?.nextObject() as? String {
            var status = stat()
            let full = directory.appendingPathComponent(relative).path
            guard lstat(full, &status) == 0 else { continue }
            entries.append("\(relative):\(status.st_size):\(status.st_mtimespec.tv_sec)")
        }
        return entries.sorted()
    }
}

/// A repository whose answers the test states outright, so no real repository
/// and no `git` process is involved.
private struct ScriptedOracle: RepositoryOracle {
    let tracked: [String: Bool]
    let ignored: [String: Bool]

    func ignores(path: String, repositoryPath _: String) -> Bool? { ignored[path] }
    func tracksContents(ofPath path: String, repositoryPath _: String) -> Bool? { tracked[path] }
}
