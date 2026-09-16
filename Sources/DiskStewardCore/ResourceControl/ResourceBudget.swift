import Darwin
import Foundation

public struct ResourceBudget: Equatable, Sendable {
    public let maximumIdleCPUPercent: Double
    public let maximumLoadCPUPercent: Double
    public let maximumResidentBytes: Int64
    public let maximumDatabaseBytes: Int64
    public let maximumPendingEvents: Int
    public let maximumLossRatio: Double

    public init(
        maximumIdleCPUPercent: Double = 1,
        maximumLoadCPUPercent: Double = 15,
        maximumResidentBytes: Int64 = 150 * 1_024 * 1_024,
        maximumDatabaseBytes: Int64 = 512 * 1_024 * 1_024,
        maximumPendingEvents: Int = 4_096,
        maximumLossRatio: Double = 0.01
    ) {
        self.maximumIdleCPUPercent = max(0, maximumIdleCPUPercent)
        self.maximumLoadCPUPercent = max(self.maximumIdleCPUPercent, maximumLoadCPUPercent)
        self.maximumResidentBytes = max(16 * 1_024 * 1_024, maximumResidentBytes)
        self.maximumDatabaseBytes = max(10 * 1_024 * 1_024, maximumDatabaseBytes)
        self.maximumPendingEvents = min(65_536, max(1, maximumPendingEvents))
        self.maximumLossRatio = min(1, max(0, maximumLossRatio))
    }
}

public struct ResourceMeasurement: Equatable, Sendable {
    public let cpuPercent: Double
    public let residentBytes: Int64
    public let databaseBytes: Int64
    public let pendingEvents: Int
    public let receivedEvents: Int
    public let droppedEvents: Int
    public let underLoad: Bool

    public init(cpuPercent: Double, residentBytes: Int64, databaseBytes: Int64, pendingEvents: Int, receivedEvents: Int, droppedEvents: Int, underLoad: Bool) {
        self.cpuPercent = max(0, cpuPercent)
        self.residentBytes = max(0, residentBytes)
        self.databaseBytes = max(0, databaseBytes)
        self.pendingEvents = max(0, pendingEvents)
        self.receivedEvents = max(0, receivedEvents)
        self.droppedEvents = max(0, droppedEvents)
        self.underLoad = underLoad
    }
}

public struct ResourceBudgetAssessment: Equatable, Sendable {
    public let withinBudget: Bool
    public let backpressureRequired: Bool
    public let reasons: [String]
    public let lossRatio: Double
}

public struct ResourceBudgetEvaluator: Sendable {
    public init() {}

    public func assess(_ measurement: ResourceMeasurement, against budget: ResourceBudget) -> ResourceBudgetAssessment {
        var reasons: [String] = []
        let cpuLimit = measurement.underLoad ? budget.maximumLoadCPUPercent : budget.maximumIdleCPUPercent
        if measurement.cpuPercent > cpuLimit { reasons.append("CPU budget exceeded.") }
        if measurement.residentBytes > budget.maximumResidentBytes { reasons.append("Resident-memory budget exceeded.") }
        if measurement.databaseBytes > budget.maximumDatabaseBytes { reasons.append("Evidence-database budget exceeded.") }
        if measurement.pendingEvents > budget.maximumPendingEvents { reasons.append("Pending-event budget exceeded.") }
        let total = measurement.receivedEvents + measurement.droppedEvents
        let loss = total == 0 ? 0 : Double(measurement.droppedEvents) / Double(total)
        if loss > budget.maximumLossRatio { reasons.append("Event-loss budget exceeded.") }
        return ResourceBudgetAssessment(
            withinBudget: reasons.isEmpty,
            backpressureRequired: measurement.pendingEvents >= budget.maximumPendingEvents || loss > budget.maximumLossRatio,
            reasons: reasons.sorted(),
            lossRatio: loss
        )
    }
}

public struct BoundedResourceHistory: Sendable {
    public let capacity: Int
    public private(set) var samples: [ResourceMeasurement] = []

    public init(capacity: Int = 120) {
        self.capacity = min(3_600, max(1, capacity))
    }

    public mutating func append(_ sample: ResourceMeasurement) {
        if samples.count == capacity { samples.removeFirst() }
        samples.append(sample)
    }
}

/// Reads only process and evidence-store metadata. It never traverses watched
/// roots, making it safe to call before potentially expensive monitoring work.
public final class LiveResourceMeasurementSource: @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPUSeconds: Double?
    private var previousUptime: TimeInterval?

    public init() {}

    public func measure(
        databaseURL: URL,
        pendingEvents: Int = 0,
        receivedEvents: Int = 0,
        droppedEvents: Int = 0,
        underLoad: Bool
    ) -> ResourceMeasurement {
        ResourceMeasurement(
            cpuPercent: intervalCPUPercent(),
            residentBytes: Self.residentBytes(),
            databaseBytes: Self.databaseFamilyBytes(databaseURL),
            pendingEvents: pendingEvents,
            receivedEvents: receivedEvents,
            droppedEvents: droppedEvents,
            underLoad: underLoad
        )
    }

    private static func residentBytes() -> Int64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
    }

    private func intervalCPUPercent() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let cpu = user + system
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        defer {
            previousCPUSeconds = cpu
            previousUptime = uptime
        }
        guard let previousCPUSeconds, let previousUptime else { return 0 }
        return max(0, (cpu - previousCPUSeconds) / max(0.001, uptime - previousUptime) * 100)
    }

    private static func databaseFamilyBytes(_ url: URL) -> Int64 {
        [url.path, url.path + "-wal", url.path + "-shm"]
            .reduce(into: Int64(0)) { total, path in
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attributes[.size] as? NSNumber
                else { return }
                total += size.int64Value
            }
    }
}

public enum ResourceCircuitBreaker {
    /// CPU pressure should slow scheduling, but memory, live storage, and an
    /// overflowing event inbox must stop detailed collection immediately.
    public static func mustStop(_ assessment: ResourceBudgetAssessment) -> Bool {
        assessment.backpressureRequired || assessment.reasons.contains {
            $0 == "Resident-memory budget exceeded." || $0 == "Evidence-database budget exceeded."
        }
    }
}
