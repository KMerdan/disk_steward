import Combine
import Foundation

protocol SettingsPersisting: AnyObject {
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsPersisting {}

final class EphemeralSettingsPersistence: SettingsPersisting {
    private var values: [String: Data] = [:]

    func data(forKey defaultName: String) -> Data? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value as? Data }
}

@MainActor
final class MonitoringSettingsStore: ObservableObject {
    @Published private(set) var settings: MonitoringSettings

    private let persistence: SettingsPersisting
    private let key: String

    init(persistence: SettingsPersisting = UserDefaults.standard, key: String = "monitoring-settings-v1") {
        self.persistence = persistence
        self.key = key
        if let data = persistence.data(forKey: key), var decoded = try? JSONDecoder().decode(MonitoringSettings.self, from: data) {
            decoded.normalize()
            settings = decoded
        } else {
            settings = .defaults
        }
    }

    func update(_ mutation: (inout MonitoringSettings) -> Void) {
        var updated = settings
        mutation(&updated)
        updated.normalize()
        settings = updated
        persist()
    }

    func addWatchedRoot(_ url: URL) {
        update { $0.watchedRoots.append(url.path) }
    }

    func removeWatchedRoot(_ path: String) {
        update { $0.watchedRoots.removeAll { $0 == path } }
    }

    func addExcludedRoot(_ url: URL) {
        update { $0.excludedRoots.append(url.path) }
    }

    func removeExcludedRoot(_ path: String) {
        update { $0.excludedRoots.removeAll { $0 == path } }
    }

    func beginInvestigation(root: String, hours: Int, now: Date = Date()) {
        update {
            $0.investigationRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            $0.investigationExpiresAt = now.addingTimeInterval(TimeInterval(min(24, max(1, hours))) * 3_600)
        }
    }

    func endInvestigation() {
        update {
            $0.investigationRoot = nil
            $0.investigationExpiresAt = nil
        }
    }

    private func persist() {
        persistence.set(try? JSONEncoder().encode(settings), forKey: key)
    }
}
