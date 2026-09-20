import Foundation

/// Reads a repository's ignore rules and index through `git`, and nothing else:
/// no fetch, no checkout, no hook, no project tooling. Every answer is
/// optional, so a missing git, a timeout, or a repository in an unusual state
/// decides nothing and classification falls through to other evidence.
public final class GitRepositoryOracle: RepositoryOracle, @unchecked Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var ignoreAnswers: [String: Bool] = [:]
    private var trackedAnswers: [String: Bool] = [:]

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"), timeout: TimeInterval = 10) {
        self.executableURL = executableURL
        self.timeout = min(60, max(1, timeout))
    }

    public func ignores(path: String, repositoryPath: String) -> Bool? {
        cached(&ignoreAnswers, key: repositoryPath + "\u{0}" + path) {
            run(["-C", repositoryPath, "check-ignore", "--quiet", "--", path]).map { $0 == 0 }
        }
    }

    public func tracksContents(ofPath path: String, repositoryPath: String) -> Bool? {
        cached(&trackedAnswers, key: repositoryPath + "\u{0}" + path) {
            run(["-C", repositoryPath, "ls-files", "--error-unmatch", "--", path]).map { $0 == 0 }
        }
    }

    private func cached(_ store: inout [String: Bool], key: String, compute: () -> Bool?) -> Bool? {
        lock.lock()
        if let answer = store[key] { lock.unlock(); return answer }
        lock.unlock()
        guard let answer = compute() else { return nil }
        lock.lock(); store[key] = answer; lock.unlock()
        return answer
    }

    /// Exit status, or nil when git could not be asked or did not answer in time.
    private func run(_ arguments: [String]) -> Int32? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // A clean environment: no credential helper, no pager, no prompting,
        // no inherited configuration that could make git do work of its own.
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "GIT_CONFIG_NOSYSTEM": "1",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(2_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus
    }
}
