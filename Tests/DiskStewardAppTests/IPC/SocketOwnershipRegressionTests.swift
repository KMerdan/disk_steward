import Darwin
@testable import DiskStewardCore
import Foundation
import XCTest

final class SocketOwnershipRegressionTests: XCTestCase {
    func testSocketReadDeadlineCapAndDisconnectedWrite() throws {
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { for descriptor in descriptors where descriptor >= 0 { Darwin.close(descriptor) } }
        try BoundedSocketIO.configure(descriptors[0])
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BoundedSocketIO.readLine(from: descriptors[0], maximumBytes: 32, deadline: started + 0.05, isCancelled: { false })) { error in
            guard case DiskStewardIPCError.remote(let code, _, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "deadline_exceeded")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        let oversized = Data(repeating: 65, count: 64)
        _ = oversized.withUnsafeBytes { Darwin.write(descriptors[1], $0.baseAddress, $0.count) }
        XCTAssertThrowsError(try BoundedSocketIO.readLine(from: descriptors[0], maximumBytes: 32, deadline: started + 1, isCancelled: { false })) { error in
            XCTAssertEqual(error as? DiskStewardIPCError, .responseTooLarge)
        }
        Darwin.close(descriptors[1])
        descriptors[1] = -1
        XCTAssertThrowsError(try BoundedSocketIO.write(Data([1]), to: descriptors[0], deadline: started + 1, isCancelled: { false }))
    }

    func testLeaseRefusesSymlinkAndNonPrivateLock() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appending(path: "target")
        let link = root.appending(path: "lock")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try LocalServiceLease(url: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sentinel")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        XCTAssertThrowsError(try LocalServiceLease(url: target))
    }
    func testSecondServerCannotReplaceLiveEndpointOrRemoveItOnFailedStart() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-owner-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "service.sock").path
        let first = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        let second = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        try first.start()
        defer { first.stop() }
        var before = stat()
        XCTAssertEqual(lstat(path, &before), 0)
        XCTAssertThrowsError(try second.start())
        second.stop()
        var after = stat()
        XCTAssertEqual(lstat(path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        let value = try UnixSocketDiskStewardIPCClient(socketPath: path).call(tool: "echo", arguments: [:], isCancelled: { false })
        XCTAssertEqual(value, .string("alive"))
    }

    func testLeaseCanBeReacquiredAfterNormalStop() async throws {
        let root = URL(fileURLWithPath: "/tmp/ds-reuse-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "service.sock").path
        let first = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        let second = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        try first.start()
        first.stop()
        try second.start()
        defer { second.stop() }
        first.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testUnknownListenerIsPreservedWithoutAnyProbeConnection() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let listener = try rawListener(path)
        defer { Darwin.close(listener) }
        let before = try identity(path)
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        XCTAssertThrowsError(try server.start()) { error in
            guard case DiskStewardIPCError.remote(let code, _, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "endpoint_ownership_unknown")
        }
        server.stop()
        XCTAssertEqual(try identity(path), before)
        // A connection probe is itself unsafe for old listeners. The backlog
        // must remain empty, not merely have the same socket inode.
        XCTAssertEqual(Darwin.accept(listener, nil, nil), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        let released = try LocalServiceLease(url: URL(fileURLWithPath: path + ".lock"))
        withExtendedLifetime(released) {}
    }

    // Disk Steward 1.1 never removed its socket on quit and never wrote a lease
    // record. Upgrading must recover that leftover without probing it.
    func testLeftoverLegacySocketWithoutAnyHolderIsRecoveredOnUpgrade() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        Darwin.close(try rawListener(path)) // a legacy app that exited without unlinking
        XCTAssertEqual(ProcessSocketTable.pids(boundTo: path), [], "nobody holds the leftover socket")
        let inspector = LegacyEndpointInspector(listeners: ProcessSocketTable.pids(boundTo:), otherApplicationRunning: { false })
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo(), legacyEndpointInspector: inspector, startupCheckpoint: { _ in })
        try server.start()
        defer { server.stop() }
        let value = try UnixSocketDiskStewardIPCClient(socketPath: path).call(tool: "echo", arguments: [:], isCancelled: { false })
        XCTAssertEqual(value, .string("alive"))
    }

    func testLegacySocketIsPreservedWhileAnotherAppRunsOrTheProcessTableIsUnreadable() throws {
        let cases: [(String, LegacyEndpointInspector)] = [
            ("another Disk Steward app is running", LegacyEndpointInspector(listeners: { _ in [] }, otherApplicationRunning: { true })),
            ("the process table cannot be read", LegacyEndpointInspector(listeners: { _ in nil }, otherApplicationRunning: { false })),
            ("a process holds the socket", LegacyEndpointInspector(listeners: { _ in [4242] }, otherApplicationRunning: { false })),
        ]
        for (label, inspector) in cases {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appending(path: "s").path
            Darwin.close(try rawListener(path))
            let before = try identity(path)
            let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo(), legacyEndpointInspector: inspector, startupCheckpoint: { _ in })
            XCTAssertThrowsError(try server.start(), label) { error in
                guard case DiskStewardIPCError.remote(let code, _, _) = error else { return XCTFail("\(label): \(error)") }
                XCTAssertEqual(code, "endpoint_ownership_unknown", label)
            }
            server.stop()
            XCTAssertEqual(try identity(path), before, label)
        }
    }

    func testProcessTableFindsALiveListenerWithoutConnecting() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let listener = try rawListener(path)
        XCTAssertEqual(ProcessSocketTable.pids(boundTo: path), [getpid()])
        XCTAssertFalse(LegacyEndpointInspector(listeners: ProcessSocketTable.pids(boundTo:), otherApplicationRunning: { false }).isStale(path))
        XCTAssertEqual(Darwin.accept(listener, nil, nil), -1, "the scan never connects")
        XCTAssertEqual(errno, EWOULDBLOCK)
        Darwin.close(listener)
        XCTAssertEqual(ProcessSocketTable.pids(boundTo: path), [])
    }

    func testFailedStartPreservesRegularAndSymlinkOccupantsAndCanRetry() throws {
        for isLink in [false, true] {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = root.appending(path: "sentinel")
            let socket = root.appending(path: "s")
            try Data("keep".utf8).write(to: target)
            if isLink {
                try FileManager.default.createSymbolicLink(at: socket, withDestinationURL: target)
            } else {
                try Data("occupant".utf8).write(to: socket)
            }
            let before = try identity(socket.path)
            let server = UnixSocketEvidenceServer(socketPath: socket.path, handler: Echo())
            XCTAssertThrowsError(try server.start())
            server.stop()
            XCTAssertEqual(try identity(socket.path), before)
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
            try FileManager.default.removeItem(at: socket) // fixture occupant only
            try server.start()
            server.stop()
        }
    }

    func testStopPreservesAReplacementSocketAndItsPendingConnections() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let retired = root.appending(path: "retired").path
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(rename(path, retired), 0)
        let replacement = try rawListener(path)
        defer { Darwin.close(replacement) }
        let before = try identity(path)
        server.stop()
        XCTAssertEqual(try identity(path), before)
        XCTAssertEqual(Darwin.accept(replacement, nil, nil), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        let successor = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        XCTAssertThrowsError(try successor.start())
        successor.stop()
        XCTAssertEqual(try identity(path), before)
    }

    func testPersistentLeaseInodeIsReusedAndHardLinksAreRejected() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "application.lock")
        var lease: LocalServiceLease? = try LocalServiceLease(url: path)
        let before = try identity(path.path)
        XCTAssertThrowsError(try LocalServiceLease(url: path))
        withExtendedLifetime(lease) {}
        lease = nil
        let reacquired = try LocalServiceLease(url: path)
        XCTAssertEqual(try identity(path.path), before)
        withExtendedLifetime(reacquired) {}
        let hardlink = root.appending(path: "hardlink")
        XCTAssertEqual(link(path.path, hardlink.path), 0)
        XCTAssertThrowsError(try LocalServiceLease(url: hardlink))
        XCTAssertEqual(try identity(path.path), before)
    }

    func testCrashOwnerProcessFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["DISK_STEWARD_CRASH_FIXTURE"] else { return }
        // This subprocess never starts the application or reads preferences.
        let root = URL(fileURLWithPath: path)
        var metadata = stat()
        guard path.hasPrefix("/private/tmp/ds512-"), !path.contains(".."),
              lstat(path, &metadata) == 0, metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o077 == 0,
              try String(contentsOf: root.appending(path: "sentinel"), encoding: .utf8) == "fixture-only"
        else { return XCTFail("Refused non-private crash fixture") }
        let lease = try LocalServiceLease(url: root.appending(path: "application.lock"))
        let phase = ProcessInfo.processInfo.environment["DISK_STEWARD_CRASH_PHASE"]
        let server = UnixSocketEvidenceServer(socketPath: root.appending(path: "s").path, handler: Echo(), startupCheckpoint: {
            if $0.rawValue == phase { _exit(17) }
        })
        try server.start()
        // Abrupt process exit intentionally bypasses stop/deinit. The kernel,
        // not a test stub, must release both leases.
        withExtendedLifetime((lease, server)) {
            // A requested checkpoint must actually have been reached; successful
            // startup is not equivalent to a crash at that boundary.
            _exit(phase == nil ? 17 : 18)
        }
    }

    func testAbruptProcessDeathReleasesLeaseAndRecoversRecordedSocket() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture-only".utf8).write(to: root.appending(path: "sentinel"))
        try await crashFixture(root)
        let path = root.appending(path: "s").path
        _ = try identity(path)
        let appLease = try LocalServiceLease(url: root.appending(path: "application.lock"))
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        try server.start()
        defer { server.stop() }
        let value = try UnixSocketDiskStewardIPCClient(socketPath: path).call(tool: "echo", arguments: [:], isCancelled: { false })
        XCTAssertEqual(value, .string("alive"))
        XCTAssertEqual(try String(contentsOf: root.appending(path: "sentinel"), encoding: .utf8), "fixture-only")
        withExtendedLifetime(appLease) {}
    }

    func testEveryStartupCrashBoundaryRecoversIncludingTornJournal() async throws {
        for phase in [SocketStartupCheckpoint.directoryJournaled, .bound, .journalPartiallyWritten, .endpointJournaled, .published] {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("fixture-only".utf8).write(to: root.appending(path: "sentinel"))
            let path = root.appending(path: "s").path
            // Repeat with existing journal slots, not only an empty first run.
            for _ in 0..<2 {
                try await crashFixture(root, phase: phase)
                let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
                try server.start()
                XCTAssertEqual(try UnixSocketDiskStewardIPCClient(socketPath: path, timeoutSeconds: 1).call(tool: "echo", arguments: [:], isCancelled: { false }), .string("alive"))
                server.stop()
                XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".stage/s"))
                XCTAssertEqual(try String(contentsOf: root.appending(path: "sentinel"), encoding: .utf8), "fixture-only")
                let journalSize = try FileManager.default.attributesOfItem(atPath: path + ".lock")[.size] as? NSNumber
                XCTAssertLessThanOrEqual(try XCTUnwrap(journalSize).intValue, 4_096)
            }
        }
    }

    func testThrowingStartupCheckpointsCleanOnlyOwnedResources() throws {
        for phase in [SocketStartupCheckpoint.directoryJournaled, .bound, .journalPartiallyWritten, .endpointJournaled, .published] {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appending(path: "s").path
            let broken = UnixSocketEvidenceServer(socketPath: path, handler: Echo(), startupCheckpoint: {
                if $0 == phase { throw POSIXError(.EIO) }
            })
            XCTAssertThrowsError(try broken.start())
            broken.stop()
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".stage/s"))
            let successor = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
            try successor.start()
            successor.stop()
        }
    }

    func testPublicationRefusesAnOccupantCreatedAfterTheInitialCheck() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo(), startupCheckpoint: {
            if $0 == .endpointJournaled { try Data("late occupant".utf8).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting) }
        })
        XCTAssertThrowsError(try server.start())
        server.stop()
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "late occupant")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path + ".stage/s"))
    }

    func testCrashRecoveryPreservesReplacedStagingDirectoryAndRegularFile() async throws {
        for replaceDirectory in [false, true] {
            let root = try fixtureRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("fixture-only".utf8).write(to: root.appending(path: "sentinel"))
            try await crashFixture(root, phase: .bound)
            let path = root.appending(path: "s").path
            let staged = path + ".stage/s"
            var replacement: Int32 = -1
            defer { if replacement >= 0 { Darwin.close(replacement) } }
            if replaceDirectory {
                XCTAssertEqual(rename(path + ".stage", root.appending(path: "retired-stage").path), 0)
                try FileManager.default.createDirectory(atPath: path + ".stage", withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                replacement = try rawListener(staged)
            } else {
                XCTAssertEqual(unlink(staged), 0)
                try Data("keep".utf8).write(to: URL(fileURLWithPath: staged))
            }
            let before = try identity(staged)
            let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
            XCTAssertThrowsError(try server.start())
            server.stop()
            XCTAssertEqual(try identity(staged), before)
        }
    }

    func testStopDoesNotCloseListenerUntilItsPendingHandlerDrains() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let barrier = AcceptBarrier()
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo(), beforeAccept: {
            barrier.holdFirst($0)
        }, startupCheckpoint: { _ in })
        try server.start()
        defer { barrier.release.signal(); server.stop() }
        let connection = try connectWithoutRequest(path)
        defer { Darwin.close(connection) }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 2), .success)
        let oldDescriptor = barrier.descriptor
        server.stop()
        // A paused callback still owns the descriptor. It cannot be reused by
        // the new listener or by any unrelated opener in this process.
        XCTAssertNotEqual(fcntl(oldDescriptor, F_GETFD), -1)
        try server.start()
        barrier.release.signal()
        XCTAssertEqual(try UnixSocketDiskStewardIPCClient(socketPath: path, timeoutSeconds: 1).call(tool: "echo", arguments: [:], isCancelled: { false }), .string("alive"))
        XCTAssertEqual(barrier.drained.wait(timeout: .now() + 2), .success)
    }

    private func crashFixture(_ root: URL, phase: SocketStartupCheckpoint? = nil) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "DiskStewardAppTests.SocketOwnershipRegressionTests/testCrashOwnerProcessFixture", Bundle(for: Self.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["DISK_STEWARD_CRASH_FIXTURE": root.path]) { _, new in new }
        if let phase { child.environment?["DISK_STEWARD_CRASH_PHASE"] = phase.rawValue }
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        let ended = expectation(description: "crash fixture exits")
        child.terminationHandler = { _ in ended.fulfill() }
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        await fulfillment(of: [ended], timeout: 15)
        guard !child.isRunning else { return XCTFail("Crash fixture timed out") }
        XCTAssertEqual(child.terminationStatus, 17)
    }

    private final class AcceptBarrier: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var held = false
        private var value: Int32 = -1
        var descriptor: Int32 { lock.lock(); defer { lock.unlock() }; return value }
        func holdFirst(_ descriptor: Int32) {
            lock.lock()
            guard !held else { lock.unlock(); return }
            held = true
            value = descriptor
            lock.unlock()
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            drained.signal()
        }
    }

    private func connectWithoutRequest(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buffer in
                for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count))
            }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        return fd
    }

    func testRapidRestartKeepsFirstRequestResponsive() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appending(path: "s").path
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        defer { server.stop() }
        for _ in 0..<40 {
            try server.start()
            let result = try UnixSocketDiskStewardIPCClient(socketPath: path, timeoutSeconds: 1).call(tool: "echo", arguments: [:], isCancelled: { false })
            XCTAssertEqual(result, .string("alive"))
            server.stop()
        }
    }

    func testNearCapacityPublicSocketPathStillConnectsAndRestarts() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        // public path + NUL exactly fits; adjacent ".stage/s" cannot fit.
        let padding = capacity - root.path.utf8.count - 4
        let parent = root.appending(path: String(repeating: "x", count: padding))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let path = parent.appending(path: "s").path
        XCTAssertEqual(path.utf8CString.count, capacity)
        let server = UnixSocketEvidenceServer(socketPath: path, handler: Echo())
        defer { server.stop() }
        for _ in 0..<2 {
            try server.start()
            XCTAssertEqual(try UnixSocketDiskStewardIPCClient(socketPath: path, timeoutSeconds: 1).call(tool: "echo", arguments: [:], isCancelled: { false }), .string("alive"))
            server.stop()
        }
    }

    private func fixtureRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/ds512-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func identity(_ path: String) throws -> String {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { throw POSIXError(.ENOENT) }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mode)"
    }

    private func rawListener(_ path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { buffer in
                    for (index, byte) in bytes.enumerated() { buffer[index] = byte }
                }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes.count))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(descriptor, 4) == 0 else { throw POSIXError(.EIO) }
            try BoundedSocketIO.configure(descriptor)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private struct Echo: DiskStewardIPCRequestHandling {
        func handleIPC(method: String, payload: JSONValue, peer: IPCPeerIdentity) async throws -> JSONValue { .string("alive") }
    }
}
