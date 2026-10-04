import Darwin
import Foundation

/// Answers repository questions for a review without one git process per
/// directory: the tracked listing is read once per repository with
/// `git ls-files`, and ignore questions go to one long-lived
/// `git check-ignore --stdin` per repository, so each answer is git's own
/// for that path. It reads the index and ignore rules and nothing else, like
/// `GitRepositoryOracle`; a repository that cannot be asked answers nothing.
public final class IndexedRepositoryOracle: RepositoryOracle, @unchecked Sendable {
    private let executableURL: URL
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var tracked: [String: Set<String>?] = [:]
    private var checkers: [String: IgnoreChecker] = [:]
    /// Repositories whose checker failed; they answer nothing for this review.
    private var unavailable = Set<String>()
    /// Most recently used last. The walk is depth-first, so a few open
    /// checkers cover it; older ones are closed rather than left running.
    private var recent: [String] = []
    public static let maximumOpenCheckers = 4
    public private(set) var processes = 0
    public private(set) var peakOpenCheckers = 0

    public init(executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"), timeout: TimeInterval = 30) {
        self.executableURL = executableURL
        self.timeout = min(120, max(1, timeout))
    }

    deinit { for checker in checkers.values { checker.close() } }

    public func tracksContents(ofPath path: String, repositoryPath: String) -> Bool? {
        guard let relative = Self.relative(path, to: repositoryPath) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if tracked[repositoryPath] == nil { tracked[repositoryPath] = .some(loadTracked(repositoryPath)) }
        guard let directories = tracked[repositoryPath] ?? nil else { return nil }
        return relative.isEmpty ? !directories.isEmpty : directories.contains(relative)
    }

    public func ignores(path: String, repositoryPath: String) -> Bool? {
        guard let relative = Self.relative(path, to: repositoryPath), !relative.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !unavailable.contains(repositoryPath) else { return nil }
        let checker: IgnoreChecker
        if let open = checkers[repositoryPath] {
            checker = open
            recent.removeAll { $0 == repositoryPath }
        } else {
            guard let started = IgnoreChecker(executableURL: executableURL, repository: repositoryPath, environment: Self.environment, timeout: timeout) else {
                unavailable.insert(repositoryPath)
                return nil
            }
            processes += 1
            checker = started
            checkers[repositoryPath] = started
            while checkers.count > Self.maximumOpenCheckers, let oldest = recent.first {
                recent.removeFirst()
                checkers.removeValue(forKey: oldest)?.close()
            }
            peakOpenCheckers = max(peakOpenCheckers, checkers.count)
        }
        recent.append(repositoryPath)
        let answer = checker.ignores(relative)
        if answer == nil {
            checker.close()
            checkers.removeValue(forKey: repositoryPath)
            recent.removeAll { $0 == repositoryPath }
            unavailable.insert(repositoryPath)
        }
        return answer
    }

    static func relative(_ path: String, to repository: String) -> String? {
        if path == repository { return "" }
        let prefix = repository.hasSuffix("/") ? repository : repository + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    static let environment = [
        "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0",
        "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "GIT_CONFIG_NOSYSTEM": "1",
    ]

    /// Every directory that holds a tracked file, relative to the repository.
    private func loadTracked(_ repository: String) -> Set<String>? {
        guard let listing = run(["-C", repository, "ls-files", "-z"]) else { return nil }
        var directories = Set<String>()
        for file in listing.split(separator: 0) {
            var path = Substring(decoding: file, as: UTF8.self)
            while let slash = path.lastIndex(of: "/") {
                path = path[..<slash]
                if !directories.insert(String(path)).inserted { break }
            }
        }
        return directories
    }

    /// Standard output, or nil when git could not answer in time. Input comes
    /// from a file, so a long list never deadlocks against the output pipe.
    private func run(_ arguments: [String], input: Data? = nil, acceptedStatuses: Set<Int32> = [0]) -> Data? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0", "GIT_PAGER": "cat", "GIT_CONFIG_NOSYSTEM": "1",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var inputFile: URL?
        if let input {
            let url = FileManager.default.temporaryDirectory.appending(path: "ds-check-ignore-\(UUID().uuidString)")
            guard (try? input.write(to: url)) != nil, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            inputFile = url
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
        do { try process.run() } catch { return nil }
        processes += 1 // callers hold the lock
        // Read while it runs: a large listing must never fill the pipe and stall git.
        let collected = Collected()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collected.set(output.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return acceptedStatuses.contains(process.terminationStatus) ? collected.value : nil
    }
}

private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    var value: Data { lock.withLock { data } }
}

/// One `git check-ignore --stdin -z -v --non-matching` per repository. Each
/// path is written and its record read back before the next, with a timeout;
/// GIT_FLUSH makes git answer each path as soon as it is read.
final class IgnoreChecker: @unchecked Sendable {
    private let process = Process()
    private let input: FileHandle
    private let output: Int32
    private let timeout: TimeInterval
    private var buffer = [UInt8]()

    init?(executableURL: URL, repository: String, environment: [String: String], timeout: TimeInterval) {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return nil }
        process.executableURL = executableURL
        process.arguments = ["-C", repository, "check-ignore", "--stdin", "-z", "-v", "--non-matching"]
        process.environment = environment.merging(["GIT_FLUSH": "1"]) { _, new in new }
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        input = inputPipe.fileHandleForWriting
        // A git that exits must fail the write, not raise SIGPIPE in the app.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = outputPipe.fileHandleForReading.fileDescriptor
        self.timeout = timeout
    }

    /// True when a pattern ignores the path, false when none does or a
    /// negated pattern re-includes it, nil when git did not answer.
    func ignores(_ relative: String) -> Bool? {
        guard (try? input.write(contentsOf: Data(relative.utf8) + Data([0]))) != nil else { return nil }
        var fields: [String] = []
        let deadline = Date().addingTimeInterval(timeout)
        while fields.count < 4 {
            if let end = buffer.firstIndex(of: 0) {
                fields.append(String(decoding: buffer[..<end], as: UTF8.self))
                buffer.removeSubrange(...end)
                continue
            }
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow) * 1_000)
            guard remaining > 0, poll(&descriptor, 1, remaining) > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = read(output, &chunk, chunk.count)
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[..<count])
        }
        // source, line number, pattern, path: an empty source matched nothing.
        guard !fields[0].isEmpty else { return false }
        return !fields[2].hasPrefix("!")
    }

    func close() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}
