import Foundation
import Darwin
import XCTest
@testable import DiskStewardApp

final class CommandRunnerRegressionTests: XCTestCase {
    func testDrainsOneMiBFromEachPipeAndPreservesFastExitStatus() async throws {
        let result = try await FoundationAgentCommandRunner(timeoutSeconds: 5).run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/usr/bin/head -c 1048576 /dev/zero & /usr/bin/head -c 1048576 /dev/zero >&2 & wait; exit 7"]))
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertEqual(result.standardOutput.utf8.count, 1_048_576)
        XCTAssertEqual(result.standardError.utf8.count, 1_048_576)
    }

    func testParentExitDoesNotLeaveAnInheritedPipeChildAlive() async throws {
        let fixture = try OwnedCommandFixture()
        defer { fixture.cleanUp() }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await FoundationAgentCommandRunner(timeoutSeconds: 2).run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "/bin/sleep 15 & echo $! > \"$1\"; exit 0", "fixture", fixture.childPID.path]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        let pid = try fixture.recordedPID()
        XCTAssertFalse(fixture.isRunning(pid), "The owned command's pipe-holding descendant must be stopped before return")
    }

    func testCancellationStopsTermIgnoringChildAndItsDescendantBeforeReturning() async throws {
        let fixture = try OwnedCommandFixture()
        defer { fixture.cleanUp() }
        let runner = FoundationAgentCommandRunner(timeoutSeconds: 4)
        let command = AgentCommand(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; /bin/sleep 15 & echo $! > \"$2\"; wait", "fixture", fixture.parentPID.path, fixture.childPID.path])
        let running = Task { try await runner.run(command) }
        defer { running.cancel() }
        let beganBy = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: fixture.childPID.path), ProcessInfo.processInfo.systemUptime < beganBy {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try fixture.recordedPID()
        let parent = try fixture.recordedPID(at: fixture.parentPID)
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        running.cancel()
        do { _ = try await running.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stoppedAt, 2)
        try assertReaped([parent])
        XCTAssertFalse(fixture.isRunning(pid), "TERM-ignoring descendant must not survive cancellation")
    }

    func testSpawnFailureAndAlreadyCancelledCallRecover() async throws {
        let runner = FoundationAgentCommandRunner(timeoutSeconds: 1)
        do {
            _ = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/private/tmp/ds-no-executable-\(UUID().uuidString)"), arguments: []))
            XCTFail("Expected spawn failure")
        } catch {}
        let command = AgentCommand(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await runner.run(command); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        XCTAssertTrue(cancelled)
        for _ in 0..<20 {
            let result = try await runner.run(command)
            XCTAssertEqual(result.exitCode, 0)
        }
    }

    func testParentExitAlsoStopsDescendantWithClosedOutputPipes() async throws {
        let fixture = try OwnedCommandFixture()
        defer { fixture.cleanUp() }
        let result = try await FoundationAgentCommandRunner(timeoutSeconds: 2).run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; /bin/sleep 15 >/dev/null 2>&1 & echo $! > \"$1\"; exit 0", "fixture", fixture.childPID.path]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(fixture.isRunning(try fixture.recordedPID()), "EOF is not proof the process group is finished")
    }

    func testCancellationAtBothSpawnBoundariesHasOneCompletionAndReapsOwnedLeader() async throws {
        for beforeSpawn in [true, false] {
            for _ in 0..<10 {
                let gate = CommandSpawnGate()
                defer { gate.open() }
                let hooks = AgentCommandLifecycleHooks(
                    beforeSpawn: { if beforeSpawn { gate.arriveAndWait() } },
                    afterSpawn: { pid in gate.record(pid); if !beforeSpawn { gate.arriveAndWait() } })
                let runner = FoundationAgentCommandRunner(timeoutSeconds: 2, hooks: hooks)
                let operation = Task { try await runner.run(.init(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["15"])) }
                defer { operation.cancel() }
                try await waitFor { gate.arrived }
                operation.cancel()
                gate.open()
                do { _ = try await operation.value; XCTFail("Cancellation must win at the held spawn boundary") }
                catch is CancellationError {} catch { XCTFail("Unexpected boundary error: \(error)") }
                if beforeSpawn { XCTAssertEqual(gate.pids, [], "Pre-spawn cancellation must launch nothing") }
                else { try assertReaped(gate.pids) }
                XCTAssertFalse(gate.waitTimedOut)
            }
        }
    }

    func testFourOwnedCommandsAreCountedUntilCleanupAndRefuseAFifth() async throws {
        let gates = (0..<4).map { _ in CommandSpawnGate() }
        let operations = gates.map { gate in
            Task {
                try await FoundationAgentCommandRunner(timeoutSeconds: 4, hooks: .init(afterSpawn: { pid in
                    gate.record(pid); gate.arriveAndWait()
                })).run(.init(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["15"]))
            }
        }
        defer { operations.forEach { $0.cancel() }; gates.forEach { $0.open() } }
        try await waitFor { gates.allSatisfy(\.arrived) }
        do {
            _ = try await FoundationAgentCommandRunner().run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
            XCTFail("The global command admission cap must include other runner instances")
        } catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .commandLimitReached) }
        operations.forEach { $0.cancel() }
        // Deliberately hold the lifecycle owner. The caller must still finish,
        // but its slot must not be released while it owns a child.
        for operation in operations {
            do { _ = try await operation.value; XCTFail("Expected bounded cleanup error") }
            catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .cleanupIncomplete) }
        }
        do {
            _ = try await FoundationAgentCommandRunner().run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
            XCTFail("Returning an error must not forget child ownership")
        } catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .commandLimitReached) }
        gates.forEach { $0.open() }
        try await waitFor { gates.flatMap(\.pids).allSatisfy { self.wasReaped($0) } }
        try await waitForAdmissionRecovery()
    }

    func testSpawnDelayIsIncludedInOverallDeadlineAndDoesNotLaunchAfterExpiry() async throws {
        let gate = CommandSpawnGate()
        defer { gate.open() }
        let runner = FoundationAgentCommandRunner(timeoutSeconds: 0.05, hooks: .init(
            beforeSpawn: { gate.arriveAndWait() }, afterSpawn: { gate.record($0) }))
        let started = ProcessInfo.processInfo.systemUptime
        let operation = Task { try await runner.run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])) }
        try await waitFor { gate.arrived }
        do { _ = try await operation.value; XCTFail("Expected the watchdog to bound stalled spawn preparation") }
        catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .cleanupIncomplete) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
        gate.open()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(gate.pids, [])
        XCTAssertFalse(gate.waitTimedOut)
    }

    func testEnvironmentWorkingDirectoryStdinAndDelayedOutputArePreserved() async throws {
        let fixture = try OwnedCommandFixture()
        defer { fixture.cleanUp() }
        let before = FileManager.default.currentDirectoryPath
        let result = try await FoundationAgentCommandRunner().run(.init(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n' \"$DS542_VALUE\"; /bin/pwd -P; /bin/sleep 0.03; if read value; then exit 9; fi; printf suffix >&2"],
            environment: ["DS542_VALUE": "value with spaces"], workingDirectoryURL: fixture.root))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, "value with spaces\n\(fixture.root.path)\n")
        XCTAssertEqual(result.standardError, "suffix")
        XCTAssertEqual(FileManager.default.currentDirectoryPath, before, "Do not change the application's working directory")
    }

    func testHugeOutputAndNeverExitStopAndReapTheOwnedProcessGroup() async throws {
        for hugeOutput in [true, false] {
            let fixture = try OwnedCommandFixture()
            let observation = CommandSpawnGate()
            defer { fixture.cleanUp() }
            let script = hugeOutput
                ? "trap '' TERM; /usr/bin/head -c 1048576 /dev/zero >&2 & echo $! > \"$1\"; wait"
                : "trap '' TERM; /bin/sleep 15 & echo $! > \"$1\"; wait"
            let runner = FoundationAgentCommandRunner(timeoutSeconds: hugeOutput ? 2 : 0.15, maximumOutputBytes: 1_024,
                                                      hooks: .init(afterSpawn: { observation.record($0) }))
            do {
                _ = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script, "fixture", fixture.childPID.path]))
                XCTFail("Expected a bounded failure")
            } catch { XCTAssertEqual(error as? AgentIntegrationCommandError, hugeOutput ? .outputLimitExceeded : .timedOut) }
            XCTAssertFalse(fixture.isRunning(try fixture.recordedPID()))
            try assertReaped(observation.pids)
        }
    }

    func testRepeatedSuccessAndSpawnFailuresDoNotLeakDescriptorsOrZombies() async throws {
        let observation = CommandSpawnGate()
        let runner = FoundationAgentCommandRunner(hooks: .init(afterSpawn: { observation.record($0) }))
        let before = openDescriptors()
        for _ in 0..<50 {
            let result = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
            XCTAssertEqual(result.exitCode, 0)
            do {
                _ = try await runner.run(.init(executableURL: URL(fileURLWithPath: "/private/tmp/ds542-missing-\(UUID().uuidString)"), arguments: []))
                XCTFail("Expected missing executable")
            } catch {}
        }
        try assertReaped(observation.pids)
        // Continuation delivery precedes the worker's final descriptor closes.
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(openDescriptors().subtracting(before), [], "Repeated invocations must not accumulate FDs")
    }

    private func waitFor(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Fixture condition did not become true within its bounded wait")
    }

    private func waitForAdmissionRecovery() async throws {
        for _ in 0..<100 {
            do {
                _ = try await FoundationAgentCommandRunner().run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/true"), arguments: []))
                return
            } catch AgentIntegrationCommandError.commandLimitReached { try await Task.sleep(for: .milliseconds(5)) }
        }
        XCTFail("Command admission did not recover after cleanup")
    }

    private func wasReaped(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        // WNOWAIT proves no waitable child remains without stealing ownership
        // from the command worker if it has not finished yet.
        var info = siginfo_t()
        status = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return status == -1 && errno == ECHILD
    }

    private func assertReaped(_ pids: [pid_t]) throws {
        XCTAssertFalse(pids.isEmpty)
        for pid in pids { XCTAssertTrue(wasReaped(pid), "Owned leader \(pid) must be reaped") }
    }

    private func openDescriptors() -> Set<Int32> {
        Set((0..<Int32(getdtablesize())).filter { fcntl($0, F_GETFD) != -1 })
    }

    func testDrainsMoreThanPipeCapacityWithoutDeadlock() async throws {
        let result = try await FoundationAgentCommandRunner(timeoutSeconds: 3).run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1048576", "/dev/zero"]))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput.utf8.count, 1_048_576)
    }

    func testTimeoutAndOutputLimitsAreEnforced() async {
        do {
            _ = try await FoundationAgentCommandRunner(timeoutSeconds: 0.05).run(.init(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]))
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .timedOut) }
        do {
            _ = try await FoundationAgentCommandRunner(maximumOutputBytes: 1_024).run(.init(executableURL: URL(fileURLWithPath: "/usr/bin/head"), arguments: ["-c", "1048576", "/dev/zero"]))
            XCTFail("Expected output cap")
        } catch { XCTAssertEqual(error as? AgentIntegrationCommandError, .outputLimitExceeded) }
    }
}

private final class CommandSpawnGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var didArrive = false
    private var timedOut = false
    private var launched: [pid_t] = []
    var arrived: Bool { lock.withLock { didArrive } }
    var waitTimedOut: Bool { lock.withLock { timedOut } }
    var pids: [pid_t] { lock.withLock { launched } }
    func record(_ pid: pid_t) { lock.withLock { launched.append(pid) } }
    func arriveAndWait() {
        lock.withLock { didArrive = true }
        if release.wait(timeout: .now() + 3) == .timedOut { lock.withLock { timedOut = true } }
    }
    func open() { release.signal() }
}

private final class OwnedCommandFixture {
    let root: URL
    var childPID: URL { root.appending(path: "child.pid") }
    var parentPID: URL { root.appending(path: "parent.pid") }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp/ds542-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func recordedPID(at file: URL? = nil) throws -> pid_t {
        let text = try String(contentsOf: file ?? childPID, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else { throw POSIXError(.EINVAL) }
        return pid
    }

    func isRunning(_ pid: pid_t) -> Bool {
        guard pid > 1 else { return false }
        // A killed orphan can briefly remain a zombie while launchd reaps it.
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            XCTAssertEqual(errno, ESRCH, "An inspection error is not proof that a process stopped")
            return false
        }
        return info.pbi_status != SZOMB
    }

    func cleanUp() {
        // Do not signal recorded numeric PIDs here: once the runner reaps its
        // leader, those identifiers are no longer ours. Synthetic workloads
        // are finite (sleep/head); the runner owns cancellation and cleanup.
        try? FileManager.default.removeItem(at: root)
    }
}
