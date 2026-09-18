import Foundation
import Darwin

struct SystemAgentDetectionEnvironment: AgentDetectionEnvironment {
    private let environment: [String: String]
    private let homeDirectory: URL

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func executableURL(named name: String) -> URL? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let boundedDirectories = pathDirectories + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            homeDirectory.appending(path: ".local/bin").path,
        ]
        var seen = Set<String>()
        for directory in boundedDirectories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    func applicationExists(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// Internal injection points make the two otherwise tiny spawn/cancel windows
// deterministic in isolated regressions. Production callers use empty hooks.
struct AgentCommandLifecycleHooks: Sendable {
    var beforeSpawn: (@Sendable () -> Void)?
    var afterSpawn: (@Sendable (pid_t) -> Void)?
}

actor FoundationAgentCommandRunner: AgentCommandRunning {
    private let timeoutSeconds: TimeInterval
    private let maximumOutputBytes: Int
    private let hooks: AgentCommandLifecycleHooks

    init(timeoutSeconds: TimeInterval = 15, maximumOutputBytes: Int = 2 * 1_024 * 1_024, hooks: AgentCommandLifecycleHooks = .init()) {
        self.timeoutSeconds = min(60, max(0.05, timeoutSeconds))
        self.maximumOutputBytes = min(4 * 1_024 * 1_024, max(1_024, maximumOutputBytes))
        self.hooks = hooks
    }

    func run(_ command: AgentCommand) async throws -> AgentCommandResult {
        try Task.checkCancellation()
        guard CommandAdmission.shared.acquire() else { throw AgentIntegrationCommandError.commandLimitReached }
        let invocation = CommandInvocation(timeout: timeoutSeconds)
        let limit = maximumOutputBytes, hooks = hooks
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.install { continuation.resume(with: $0) }
                CommandAdmission.queue.async {
                    // A delayed OS reap retains this admission slot even after
                    // a bounded error has been delivered to the caller.
                    defer { CommandAdmission.shared.release() }
                    do { try OwnedAgentCommand(command, invocation: invocation, limit: limit, hooks: hooks).run() }
                    catch { invocation.finish(.failure(error)) }
                }
            }
        } onCancel: { invocation.cancel() }
    }
}

private final class CommandAdmission: @unchecked Sendable {
    static let shared = CommandAdmission()
    static let queue = DispatchQueue(label: "DiskSteward.CommandLifecycle", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private var count = 0
    func acquire() -> Bool {
        lock.withLock { guard count < 4 else { return false }; count += 1; return true }
    }
    func release() { lock.withLock { count -= 1 } }
}

private final class CommandInvocation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var completed = false
    private var completion: (@Sendable (Result<AgentCommandResult, Error>) -> Void)?
    private var pendingResult: Result<AgentCommandResult, Error>?
    private var watchdog: DispatchSourceTimer?
    let deadline: TimeInterval

    init(timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { [weak self] in self?.finish(.failure(AgentIntegrationCommandError.cleanupIncomplete)) }
        timer.schedule(deadline: .now() + timeout + 0.75)
        watchdog = timer
        timer.resume()
    }

    var stopError: Error? {
        lock.withLock {
            if cancelled { return CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { return AgentIntegrationCommandError.timedOut }
            return nil
        }
    }

    func cancel() {
        lock.withLock {
            if !completed {
                cancelled = true
                // The caller stays bounded even if spawn or kernel cleanup is
                // delayed. Its worker retains admission and ownership meanwhile.
                watchdog?.schedule(deadline: .now() + max(0, min(0.75, deadline + 0.75 - ProcessInfo.processInfo.systemUptime)))
            }
        }
    }
    func install(_ completion: @escaping @Sendable (Result<AgentCommandResult, Error>) -> Void) {
        let pending = lock.withLock { () -> Result<AgentCommandResult, Error>? in
            if let pendingResult { self.pendingResult = nil; return pendingResult }
            self.completion = completion
            return nil
        }
        if let pending { completion(pending) }
    }
    func finish(_ result: Result<AgentCommandResult, Error>) {
        let delivery = lock.withLock { () -> ((@Sendable (Result<AgentCommandResult, Error>) -> Void), Result<AgentCommandResult, Error>)? in
            guard !completed else { return nil }
            completed = true
            watchdog?.cancel(); watchdog = nil
            let delivered: Result<AgentCommandResult, Error>
            if cancelled, case .success = result { delivered = .failure(CancellationError()) }
            else { delivered = result }
            guard let completion else { pendingResult = delivered; return nil }
            self.completion = nil
            return (completion, delivered)
        }
        if let (completion, result) = delivery { completion(result) }
    }
}

// One GCD worker exclusively owns spawning, pipe reads, group signals and reap.
// Cancellation handlers never touch a PID. The leader stays waitable until the
// last group signal, preventing numeric PID/PGID reuse during cleanup.
private final class OwnedAgentCommand {
    private let command: AgentCommand
    private let invocation: CommandInvocation
    private let limit: Int
    private let hooks: AgentCommandLifecycleHooks
    private var outputFDs: [Int32] = [-1, -1]
    private var errorFDs: [Int32] = [-1, -1]

    init(_ command: AgentCommand, invocation: CommandInvocation, limit: Int, hooks: AgentCommandLifecycleHooks) {
        self.command = command; self.invocation = invocation; self.limit = limit; self.hooks = hooks
    }

    deinit {
        for fd in outputFDs + errorFDs where fd >= 0 { Darwin.close(fd) }
    }

    func run() throws {
        if let error = invocation.stopError { throw error }
        try makePipe(&outputFDs)
        try makePipe(&errorFDs)
        let pid = try spawn()
        for fds in [outputFDs, errorFDs] { Darwin.close(fds[1]) }
        outputFDs[1] = -1; errorFDs[1] = -1
        var failure: Error?
        var output = Data(), errors = Data()
        var outEOF = false, errEOF = false, leaderExited = false
        var cleanupAt: TimeInterval?
        var termSent = false, killSent = false
        var scratch = [UInt8](repeating: 0, count: 64 * 1_024)

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if failure == nil { failure = invocation.stopError }
            if !leaderExited {
                // Darwin may leave siginfo untouched on WNOHANG. Initialize it
                // on every observation; never reap before group cleanup ends.
                var information = siginfo_t()
                let observed = waitid(P_PID, id_t(pid), &information, WEXITED | WNOHANG | WNOWAIT)
                if observed == 0 { leaderExited = information.si_pid == pid }
                else if errno == ECHILD {
                    // ECHILD means ownership was lost: signalling this numeric
                    // PID/group could now hit an unrelated process.
                    invocation.finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)))
                    return
                } else if errno != EINTR {
                    // An observation error is not proof that ownership ended.
                    // Retain the owner and drive bounded failure cleanup.
                    failure = failure ?? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            for stream in 0..<2 {
                if stream == 0 ? outEOF : errEOF { continue }
                let fd = stream == 0 ? outputFDs[0] : errorFDs[0]
                let count = Darwin.read(fd, &scratch, scratch.count)
                if count == 0 { if stream == 0 { outEOF = true } else { errEOF = true } }
                else if count > 0, failure == nil {
                    if count > limit - output.count - errors.count { failure = AgentIntegrationCommandError.outputLimitExceeded }
                    else if stream == 0 { output.append(contentsOf: scratch.prefix(count)) }
                    else { errors.append(contentsOf: scratch.prefix(count)) }
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    failure = failure ?? POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    if stream == 0 { outEOF = true } else { errEOF = true }
                }
            }
            if failure != nil || leaderExited {
                if cleanupAt == nil { cleanupAt = now }
                let alive = groupHasLiveMembers(pid, afterKill: killSent)
                if alive, !termSent {
                    if kill(-pid, SIGTERM) < 0, errno != ESRCH { failure = failure ?? POSIXError(.EPERM) }
                    termSent = true
                }
                if alive, !killSent, now - cleanupAt! >= 0.15 {
                    if kill(-pid, SIGKILL) < 0, errno != ESRCH { failure = failure ?? POSIXError(.EPERM) }
                    killSent = true
                }
                if leaderExited, !alive, (outEOF && errEOF || now - cleanupAt! >= 0.75) {
                    var status: Int32 = 0
                    let reaped = waitpid(pid, &status, WNOHANG)
                    if reaped == pid {
                        // No PID or process-group signal is permitted after here.
                        if !outEOF || !errEOF { failure = failure ?? AgentIntegrationCommandError.cleanupIncomplete }
                        if let failure { invocation.finish(.failure(failure)) }
                        else {
                            let code = status & 0x7f == 0 ? (status >> 8) & 0xff : status & 0x7f
                            invocation.finish(.success(.init(exitCode: code, standardOutput: String(decoding: output, as: UTF8.self), standardError: String(decoding: errors, as: UTF8.self))))
                        }
                        return
                    }
                    if reaped < 0, errno != EINTR {
                        invocation.finish(.failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)))
                        return
                    }
                }
                if now - cleanupAt! >= 0.75 {
                    // SIGKILL is not a finite-time kernel-reap guarantee. Bound
                    // the caller while keeping this worker and its admission
                    // slot responsible for the still-owned group/leader.
                    invocation.finish(.failure(AgentIntegrationCommandError.cleanupIncomplete))
                    output.removeAll(); errors.removeAll()
                }
            }
            var waits = [pollfd(fd: outEOF ? -1 : outputFDs[0], events: Int16(POLLIN), revents: 0),
                         pollfd(fd: errEOF ? -1 : errorFDs[0], events: Int16(POLLIN), revents: 0)]
            _ = poll(&waits, nfds_t(waits.count), 10)
            // A HUP-ready descriptor with a retained pipe can otherwise spin
            // while the kernel is still completing process termination.
            if outEOF && errEOF { usleep(5_000) }
        }
    }

    private func makePipe(_ descriptors: inout [Int32]) throws {
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        for index in 0..<2 {
            if descriptors[index] < 3 {
                let duplicate = fcntl(descriptors[index], F_DUPFD_CLOEXEC, 3)
                guard duplicate >= 0 else { throw POSIXError(.EMFILE) }
                Darwin.close(descriptors[index]); descriptors[index] = duplicate
            }
            guard fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) == 0 else { throw POSIXError(.EBADF) }
        }
        guard fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK) == 0 else { throw POSIXError(.EBADF) }
    }

    private func spawn() throws -> pid_t {
        let environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
        let values = [command.executableURL.path] + command.arguments
        guard command.executableURL.isFileURL, values.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else { throw POSIXError(.EINVAL) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        for (source, target) in [(outputFDs[1], STDOUT_FILENO), (errorFDs[1], STDERR_FILENO)] {
            try checked(posix_spawn_file_actions_adddup2(&actions, source, target))
            try checked(posix_spawn_file_actions_addclose(&actions, source))
        }
        if let directory = command.workingDirectoryURL {
            guard directory.isFileURL, !directory.path.contains("\0") else { throw POSIXError(.EINVAL) }
            try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP); sigemptyset(&mask)
        try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setsigmask(&attributes, &mask))
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        let args = values.map { strdup($0) }
        let vars = environment.sorted(by: { $0.key < $1.key }).map { strdup($0.key + "=" + $0.value) }
        defer { for value in args + vars { free(value) } }
        guard args.allSatisfy({ $0 != nil }), vars.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
        var argv = args + [nil], envp = vars + [nil]
        hooks.beforeSpawn?()
        if let error = invocation.stopError { throw error }
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, command.executableURL.path, &actions, &attributes, &argv, &envp))
        guard pid > 1 else { throw POSIXError(.ECHILD) }
        hooks.afterSpawn?(pid)
        // A successfully spawned group is now owned by this worker, even if
        // cancellation arrived during posix_spawn. The loop must clean it up.
        return pid
    }

    private func groupHasLiveMembers(_ group: pid_t, afterKill: Bool) -> Bool {
        var members = [pid_t](repeating: 0, count: 256)
        let bytes = Int32(members.count * MemoryLayout<pid_t>.size)
        errno = 0
        let count = proc_listpgrppids(group, &members, bytes)
        // Unlike proc_listpids, this wrapper returns a PID count, not bytes.
        // The underlying wrapper returns zero on error and leaves errno set.
        if count < 0 || count >= members.count || (count == 0 && errno != 0) { return true }
        for pid in members.prefix(Int(count)) where pid > 0 {
            // A descendant may fork and exit between the group snapshot and
            // its status probe. Once any descendant is observed, complete the
            // group-wide KILL phase before accepting a zombies-only snapshot.
            // The unreaped leader anchors ownership throughout both phases.
            if pid != group, !afterKill { return true }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            let observed = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
            if observed == size {
                if info.pbi_pgid == UInt32(group), info.pbi_status != SZOMB { return true }
            } else if errno != ESRCH { return true }
        }
        return false
    }

    private func checked(_ code: Int32) throws {
        if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    }
}

@MainActor
class CodexCLIIntegrationAdapter: AgentIntegrationAdapting {
    struct ClientCommands: Sendable {
        let get: @Sendable (String) -> [String]
        let add: @Sendable (String, URL) -> [String]
        let remove: @Sendable (String) -> [String]
        let parseDefinition: @Sendable (String) -> AgentIntegrationDefinition?
    }

    let descriptor: AgentClientDescriptor
    let executableURL: URL
    let helperURL: URL

    private let commands: ClientCommands
    private let runner: any AgentCommandRunning
    private let receiptStore: AgentIntegrationReceiptStore
    private let fileManager: FileManager
    private let serverName: String

    init(
        descriptor: AgentClientDescriptor = AgentClientDescriptor.supported.first { $0.id == .codex }!,
        executableURL: URL,
        helperURL: URL,
        receiptStore: AgentIntegrationReceiptStore,
        runner: any AgentCommandRunning = FoundationAgentCommandRunner(),
        fileManager: FileManager = .default,
        serverName: String = "disk-steward",
        commands: ClientCommands = .codex
    ) {
        self.descriptor = descriptor
        self.executableURL = executableURL
        self.helperURL = helperURL.standardizedFileURL
        self.receiptStore = receiptStore
        self.runner = runner
        self.fileManager = fileManager
        self.serverName = serverName
        self.commands = commands
    }

    func inspect() async -> AgentIntegrationSnapshot {
        let presence: AgentClientPresence = fileManager.isExecutableFile(atPath: executableURL.path)
            ? .detected(location: executableURL.path)
            : .notDetected
        let receipt: AgentIntegrationReceipt?
        do {
            receipt = try receiptStore.receipt(for: descriptor.id)
        } catch {
            return .derive(
                descriptor: descriptor,
                presence: presence,
                inspection: .unavailable(reason: "Integration receipt cannot be read: \(error.localizedDescription)")
            )
        }

        guard case .detected = presence else {
            return .derive(descriptor: descriptor, presence: presence, inspection: receipt.map { .owned(receipt: $0) } ?? .missing)
        }

        do {
            let command = AgentCommand(executableURL: executableURL, arguments: commands.get(serverName))
            let result = try await runner.run(command)
            if result.exitCode != 0 {
                if Self.isMissingServerOutput(result.combinedOutput) {
                    return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
                }
                return .derive(
                    descriptor: descriptor,
                    presence: presence,
                    inspection: .unavailable(reason: Self.failureMessage(result, command: command))
                )
            }
            guard let definition = commands.parseDefinition(result.standardOutput) else {
                return .derive(
                    descriptor: descriptor,
                    presence: presence,
                    inspection: .malformed(reason: "\(descriptor.displayName) returned a configuration Disk Steward could not understand.")
                )
            }
            switch AgentIntegrationOwnership.resolve(current: definition, receipt: receipt) {
            case .missing:
                return .derive(descriptor: descriptor, presence: presence, inspection: .missing)
            case let .owned(receipt):
                let expected = AgentIntegrationDefinition(command: helperURL.path)
                guard receipt.definition == expected,
                      receipt.helperIdentity != nil,
                      receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
                      fileManager.isExecutableFile(atPath: helperURL.path)
                else {
                    return .derive(
                        descriptor: descriptor,
                        presence: presence,
                        inspection: .owned(receipt: receipt),
                        verification: .failed(reason: "The bundled helper path changed or is missing. Use Repair to update \(descriptor.displayName).")
                    )
                }
                return .derive(descriptor: descriptor, presence: presence, inspection: .owned(receipt: receipt))
            case let .external(definition), let .conflict(_, definition):
                return .derive(descriptor: descriptor, presence: presence, inspection: .external(definition: definition))
            }
        } catch is CancellationError {
            return .derive(descriptor: descriptor, presence: presence, inspection: .unavailable(reason: AgentIntegrationCommandError.cancelled.localizedDescription))
        } catch {
            return .derive(descriptor: descriptor, presence: presence, inspection: .unavailable(reason: error.localizedDescription))
        }
    }

    func perform(_ action: AgentIntegrationAction) async -> AgentIntegrationOperationResult {
        if Task.isCancelled {
            let snapshot = await inspect()
            return .init(clientID: descriptor.id, action: action, outcome: .failed, message: AgentIntegrationCommandError.cancelled.localizedDescription, snapshot: snapshot)
        }

        switch action {
        case .setup:
            return await setup(action: action, replacingOwnedConfiguration: false)
        case .repair:
            return await setup(action: action, replacingOwnedConfiguration: true)
        case .verify:
            return await verify()
        case .remove:
            return await remove()
        }
    }

    private func setup(action: AgentIntegrationAction, replacingOwnedConfiguration: Bool) async -> AgentIntegrationOperationResult {
        let before = await inspect()
        switch before.inspection {
        case .malformed, .unavailable: return result(action, .failed, before.statusDetail, before)
        default: break
        }
        guard case .detected = before.presence else {
            return result(action, .failed, "\(descriptor.displayName) is not installed.", before)
        }
        guard fileManager.isExecutableFile(atPath: helperURL.path) else {
            let broken = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .malformed(reason: "The bundled MCP helper is missing at \(helperURL.path). Reinstall Disk Steward.")
            )
            return result(action, .failed, broken.statusDetail, broken)
        }
        if before.state == .conflict {
            return result(action, .failed, "Disk Steward will not overwrite an entry it does not own.", before)
        }
        if before.state == .configured || before.state == .verified, !replacingOwnedConfiguration {
            return result(action, .unchanged, "Disk Steward is already configured for \(descriptor.displayName).", before)
        }

        let previous: AgentIntegrationDefinition?
        if case let .owned(receipt) = before.inspection { previous = receipt.definition } else { previous = nil }
        let expected = AgentIntegrationDefinition(command: helperURL.path)
        var attemptedMutation = false
        do {
            if replacingOwnedConfiguration,
               case .owned = before.inspection
            {
                let removeCommand = AgentCommand(executableURL: executableURL, arguments: commands.remove(serverName))
                attemptedMutation = true
                _ = try (await runner.run(removeCommand)).requireSuccess(command: removeCommand)
            }
            let addCommand = AgentCommand(executableURL: executableURL, arguments: commands.add(serverName, helperURL))
            attemptedMutation = true
            _ = try (await runner.run(addCommand)).requireSuccess(command: addCommand)
            guard try await currentDefinition() == expected else { throw CocoaError(.fileWriteFileExists) }
            let receipt = AgentIntegrationReceipt(
                clientID: descriptor.id,
                serverName: serverName,
                definition: .init(command: helperURL.path),
                helperIdentity: PrivateIntegrationFile.executableIdentity(helperURL),
                lastResult: action == .repair ? "repaired" : "configured"
            )
            try receiptStore.upsert(receipt)
            let after = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: receipt)
            )
            return result(action, .changed, "Configured \(descriptor.displayName).", after)
        } catch {
            let failure = error.localizedDescription
            if attemptedMutation {
                // Never restore over a concurrently created/modified entry. A
                // cancelled caller still gets one bounded recovery attempt.
                let recovery = Task { @MainActor in await self.restore(previous, replacing: expected) }
                let recoveryMessage = await recovery.value
                return result(action, .failed, "\(failure) \(recoveryMessage)", await inspect())
            }
            let after = await inspect()
            return result(action, .failed, failure, after)
        }
    }

    private func verify() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        guard case let .owned(receipt) = before.inspection else {
            return result(.verify, .failed, before.state == .conflict ? "Resolve the existing configuration conflict first." : "Set up \(descriptor.displayName) first.", before)
        }
        guard receipt.definition == AgentIntegrationDefinition(command: helperURL.path),
              receipt.helperIdentity != nil,
              receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
              fileManager.isExecutableFile(atPath: helperURL.path) else {
            return result(.verify, .failed, "The configured helper differs from this build or is missing. Repair before verifying.", before)
        }
        do {
            let selfCheck = AgentCommand(executableURL: helperURL, arguments: ["--self-check"])
            _ = try (await runner.run(selfCheck)).requireSuccess(command: selfCheck)
            guard try await currentDefinition() == receipt.definition,
                  receipt.helperIdentity == PrivateIntegrationFile.executableIdentity(helperURL),
                  try receiptStore.receipt(for: descriptor.id) == receipt else {
                return result(.verify, .failed, "Configuration changed during verification. Rescan before retrying.", await inspect())
            }
            var verified = receipt
            verified.lastVerifiedAt = Date()
            verified.lastResult = "verified"
            try receiptStore.upsert(verified)
            let snapshot = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: verified),
                verification: .passed(at: verified.lastVerifiedAt!)
            )
            return result(.verify, .unchanged, "The configured helper connected to Disk Steward. Restart \(descriptor.displayName) to load this configuration; evidence freshness is reported separately.", snapshot)
        } catch {
            let snapshot = AgentIntegrationSnapshot.derive(
                descriptor: descriptor,
                presence: before.presence,
                inspection: .owned(receipt: receipt),
                verification: .failed(reason: error.localizedDescription)
            )
            return result(.verify, .failed, error.localizedDescription, snapshot)
        }
    }

    private func remove() async -> AgentIntegrationOperationResult {
        let before = await inspect()
        switch before.inspection {
        case .external:
            return result(.remove, .failed, "Disk Steward will not remove an entry it does not own.", before)
        case .missing:
            do { try receiptStore.remove(clientID: descriptor.id) } catch {
                return result(.remove, .failed, error.localizedDescription, before)
            }
            return result(.remove, .unchanged, "No Disk Steward configuration was present.", before)
        case .owned, .approvalPending:
            break
        case let .malformed(reason), let .unavailable(reason):
            return result(.remove, .failed, reason, before)
        }

        do {
            let command = AgentCommand(executableURL: executableURL, arguments: commands.remove(serverName))
            _ = try (await runner.run(command)).requireSuccess(command: command)
            guard try await currentDefinition() == nil else { throw CocoaError(.fileWriteFileExists) }
            try receiptStore.remove(clientID: descriptor.id)
            let after = AgentIntegrationSnapshot.derive(descriptor: descriptor, presence: before.presence, inspection: .missing)
            return result(.remove, .changed, "Removed only Disk Steward's \(descriptor.displayName) entry.", after)
        } catch {
            let failure = error.localizedDescription
            if case let .owned(receipt) = before.inspection {
                let recovery = Task { @MainActor in await self.restore(receipt.definition, replacing: nil) }
                return result(.remove, .failed, "\(failure) \(await recovery.value)", await inspect())
            }
            return result(.remove, .failed, failure, await inspect())
        }
    }

    private func currentDefinition() async throws -> AgentIntegrationDefinition? {
        let command = AgentCommand(executableURL: executableURL, arguments: commands.get(serverName))
        let output = try await runner.run(command)
        if output.exitCode != 0, Self.isMissingServerOutput(output.combinedOutput) { return nil }
        _ = try output.requireSuccess(command: command)
        guard let value = commands.parseDefinition(output.standardOutput) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private func restore(_ previous: AgentIntegrationDefinition?, replacing written: AgentIntegrationDefinition?) async -> String {
        do {
            let current = try await currentDefinition()
            if current == previous { return "The previous configuration was restored." }
            guard current == nil || current == written else {
                return "Configuration changed concurrently; it was preserved. The original receipt was retained for recovery."
            }
            if current != nil {
                let remove = AgentCommand(executableURL: executableURL, arguments: commands.remove(serverName))
                _ = try (await runner.run(remove)).requireSuccess(command: remove)
            }
            guard try await currentDefinition() == nil else { throw CocoaError(.fileWriteFileExists) }
            if let previous {
                guard previous.configurationFingerprint == nil else { throw CocoaError(.fileWriteNoPermission) }
                let restore = AgentCommand(executableURL: executableURL,
                    arguments: commands.add(serverName, URL(fileURLWithPath: previous.command)) + previous.arguments)
                _ = try (await runner.run(restore)).requireSuccess(command: restore)
            }
            guard try await currentDefinition() == previous else { throw CocoaError(.fileWriteUnknown) }
            return "The previous configuration was restored."
        } catch {
            return "Automatic restoration failed: \(error.localizedDescription). The original receipt was retained for recovery."
        }
    }

    private func result(
        _ action: AgentIntegrationAction,
        _ outcome: AgentIntegrationOperationOutcome,
        _ message: String,
        _ snapshot: AgentIntegrationSnapshot
    ) -> AgentIntegrationOperationResult {
        .init(clientID: descriptor.id, action: action, outcome: outcome, message: message, snapshot: snapshot)
    }

    private static func isMissingServerOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("not found") || lower.contains("no mcp server") || lower.contains("does not exist")
    }

    private static func failureMessage(_ result: AgentCommandResult, command: AgentCommand) -> String {
        (try? result.requireSuccess(command: command)) == nil
            ? (AgentIntegrationCommandError.exited(
                executable: command.executableURL.path,
                code: result.exitCode,
                message: result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            ).localizedDescription)
            : "Unknown client command failure."
    }
}

extension CodexCLIIntegrationAdapter.ClientCommands {
    static let codex = CodexCLIIntegrationAdapter.ClientCommands(
        get: { ["mcp", "get", $0, "--json"] },
        add: { name, helper in ["mcp", "add", name, "--", helper.path] },
        remove: { ["mcp", "remove", $0] },
        parseDefinition: CodexCLIIntegrationAdapter.parseCodexDefinition
    )
}

extension CodexCLIIntegrationAdapter {
    nonisolated static func parseCodexDefinition(_ output: String) -> AgentIntegrationDefinition? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return findDefinition(in: object)
    }

    nonisolated static func findDefinition(in value: Any) -> AgentIntegrationDefinition? {
        if let dictionary = value as? [String: Any] {
            if dictionary["command"] is String {
                return AgentIntegrationDefinition.parse(dictionary)
            }
            if var transport = dictionary["transport"] as? [String: Any] {
                for (key, value) in dictionary where key != "transport" && key != "name" {
                    if value is NSNull { continue }
                    if key == "enabled", value as? Bool == true { continue }
                    transport["client.\(key)"] = value
                }
                return AgentIntegrationDefinition.parse(transport)
            }
        }
        return nil
    }
}
