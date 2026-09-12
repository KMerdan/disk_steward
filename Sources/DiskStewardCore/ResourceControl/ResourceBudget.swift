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
