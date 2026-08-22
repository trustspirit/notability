import Foundation
import Combine

final class MeetingStore: ObservableObject, MeetingStoreProtocol {
    @Published private(set) var allMeetings: [Meeting] = []
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { $allMeetings.eraseToAnyPublisher() }

    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // Serializes disk writes so two saves for the same meeting cannot interleave
    // and leave a partially written file behind.
    private let diskWriteQueue = DispatchQueue(label: "com.notability.MeetingStore.disk", qos: .utility)

    init(storageDirectory: URL = MeetingStore.defaultDirectory) {
        self.storageDirectory = storageDirectory
        Self.migrateLegacyStorageIfNeeded(target: storageDirectory)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    // Pre-rebrand the app stored meetings under "MeetingScribe/meetings/". Move
    // them into the new "Notability/meetings/" location on first launch so users
    // upgrading from older versions don't appear to lose their history.
    private static func migrateLegacyStorageIfNeeded(target: URL) {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/meetings")
        guard fm.fileExists(atPath: legacy.path), legacy.path != target.path else { return }
        if !fm.fileExists(atPath: target.path) {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.moveItem(at: legacy, to: target)
            return
        }
        // Target exists — copy over any meetings not yet present, then drop the legacy folder.
        let items = (try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            let dest = target.appendingPathComponent(item.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: item, to: dest)
            }
        }
        try? fm.removeItem(at: legacy)
    }

    func save(_ meeting: Meeting) {
        // In-memory update first so observers see the change immediately. If the
        // disk write fails (rare — only on disk-full or permission errors), the
        // next save will overwrite the stale file; meanwhile the UI stays
        // responsive instead of waiting on I/O before reflecting user actions.
        var updated = allMeetings.filter { $0.id != meeting.id }
        updated.append(meeting)
        updated.sort { $0.date > $1.date }
        allMeetings = updated

        let fileURL = storageDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        // sync: callers expect the meeting to be on disk when save() returns.
        diskWriteQueue.sync {
            writeMeetingToDisk(meeting, fileURL: fileURL)
        }
    }

    func fetch(id: UUID) -> Meeting? {
        allMeetings.first { $0.id == id }
    }

    func rename(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, var meeting = fetch(id: id) else { return }
        meeting.title = trimmed
        save(meeting)
    }

    func toggleActionItemCompleted(meetingId: UUID, itemId: UUID) {
        guard var meeting = fetch(id: meetingId),
              let idx = meeting.notes?.actionItems.firstIndex(where: { $0.id == itemId }) else { return }
        meeting.notes?.actionItems[idx].isCompleted.toggle()
        save(meeting)
    }

    func delete(id: UUID) {
        let fileURL = storageDirectory.appendingPathComponent("\(id.uuidString).json")
        diskWriteQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
        }
        allMeetings.removeAll { $0.id == id }
    }

    private func writeMeetingToDisk(_ meeting: Meeting, fileURL: URL) {
        do {
            let data = try encoder.encode(meeting)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[MeetingStore] Failed to persist meeting \(meeting.id): \(error)")
        }
    }

    private func loadAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        var meetings = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? decoder.decode(Meeting.self, from: Data(contentsOf: url)) }
            .sorted { $0.date > $1.date }

        // A meeting with no notes and no recorded failure was interrupted
        // mid-processing (crash or force-quit). Mark it so the UI shows an error
        // state rather than an infinite spinner. The message goes in
        // transcriptionError because that is the stage it died in, and because
        // leaving notesGenerationError clear is what lets the UI offer a retry
        // that redoes the transcription rather than notes over an empty
        // transcript. A meeting that already carries either error is left alone.
        for index in meetings.indices where Self.wasInterrupted(meetings[index]) {
            meetings[index].transcriptionError = "Recording was interrupted before it "
                + "could be transcribed. The captured audio was kept — use Retry to process it."
            let fileURL = storageDirectory
                .appendingPathComponent("\(meetings[index].id.uuidString).json")
            if let data = try? encoder.encode(meetings[index]) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        allMeetings = meetings
    }

    private static func wasInterrupted(_ meeting: Meeting) -> Bool {
        meeting.notes == nil
            && meeting.notesGenerationError == nil
            && meeting.transcriptionError == nil
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notability/meetings")
    }

    /// Session audio lives beside the meeting JSON, in its own subdirectory, and
    /// is deleted once note generation succeeds.
    static let defaultAudioDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notability")
            .appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
