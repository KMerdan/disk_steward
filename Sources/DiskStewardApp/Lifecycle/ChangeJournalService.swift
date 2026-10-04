import Combine
import DiskStewardCore
import Foundation

/// Runs the directory-level change journal (TASK-652): one FSEvents stream
/// over the watched roots, resumed from the stored event ID so sleep and
/// relaunch replay, with every delivered batch recorded and checkpointed.
@MainActor
final class ChangeJournalService {
    private let journal: ChangeJournal
    private let stream: DirectoryChangeStream
    private let latency: TimeInterval
    private var subscription: AnyCancellable?
    private(set) var roots: [String] = []
    private(set) var journalUUID: String?
    /// Set once the replay of stored history has been delivered.
    private(set) var historyDone = false
    /// The newest event ID whose batch has been recorded; never one that is
    /// delivered but not yet written.
    private(set) var recordedEventID: UInt64?

    init(journal: ChangeJournal, stream: DirectoryChangeStream = DirectoryChangeStream(), latency: TimeInterval = 5) {
        self.journal = journal
        self.stream = stream
        self.latency = latency
    }

    /// Follows the watched roots; a change of roots restarts the stream.
    func start(settingsStore: MonitoringSettingsStore) {
        subscription = settingsStore.$settings
            .map { settings in settings.monitoringPolicy(at: Date()).activeRoots(at: Date()).map(\.path).sorted() }
            .removeDuplicates()
            .sink { [weak self] roots in
                guard let self else { return }
                Task { await self.restart(roots: roots) }
            }
    }

    func restart(roots requested: [String], at date: Date = Date()) async {
        stream.stop()
        // Events arrive with real paths; attribution compares against these.
        let roots = requested.map(DirectoryChangeStream.canonicalPath)
        self.roots = roots
        historyDone = false
        recordedEventID = nil
        guard let first = roots.first else { return }
        let uuid = DirectoryChangeStream.journalUUID(for: first)
        journalUUID = uuid
        let since: UInt64
        if let uuid, let stored = try? await journal.cursor(journalUUID: uuid) {
            since = stored
        } else {
            // No cursor for this journal: the first start, or a journal whose
            // identity changed since the last checkpoint. Either way earlier
            // changes are unknown, and the gap says which.
            let reset = (try? await journal.hasAnyCursor()) == true
            try? await journal.recordGap(reason: uuid == nil ? "journal-unavailable" : (reset ? "journal-reset" : "journal-started"), path: first, at: date)
            // Start the cursor before the stream, so nothing between the two
            // can be skipped by the next launch's replay.
            since = DirectoryChangeStream.currentEventID()
            if let uuid { try? await journal.checkpoint(journalUUID: uuid, eventID: since, at: date) }
        }
        let journal = self.journal
        do {
            try stream.start(paths: roots, since: since, latency: latency) { [weak self] batch in
                Task {
                    guard (try? await journal.record(batch, roots: roots, at: Date())) != nil else { return }
                    if let uuid, let latest = batch.latestEventID {
                        try? await journal.checkpoint(journalUUID: uuid, eventID: latest, at: Date())
                    }
                    await self?.noteRecorded(batch)
                }
            }
        } catch {
            try? await journal.recordGap(reason: "stream-failed", path: first, at: date)
        }
    }

    /// Persists the newest recorded event ID; called with each capacity sample.
    func checkpoint(at date: Date = Date()) async {
        guard let journalUUID, let recordedEventID, recordedEventID > 0 else { return }
        try? await journal.checkpoint(journalUUID: journalUUID, eventID: recordedEventID, at: date)
    }

    func stop() {
        subscription = nil
        stream.stop()
    }

    private func noteRecorded(_ batch: DirectoryChangeBatch) {
        if let latest = batch.latestEventID { recordedEventID = max(recordedEventID ?? 0, latest) }
        if batch.historyDone { historyDone = true }
    }
}
