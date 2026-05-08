import Foundation
import Combine

final class MeetingStore: ObservableObject, MeetingStoreProtocol {
    @Published private(set) var allMeetings: [Meeting] = []
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { $allMeetings.eraseToAnyPublisher() }

    private let storageDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(storageDirectory: URL = MeetingStore.defaultDirectory) {
        self.storageDirectory = storageDirectory
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    func save(_ meeting: Meeting) {
        let fileURL = storageDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        do {
            let data = try encoder.encode(meeting)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[MeetingStore] Failed to persist meeting \(meeting.id): \(error)")
        }
        var updated = allMeetings.filter { $0.id != meeting.id }
        updated.append(meeting)
        updated.sort { $0.date > $1.date }
        allMeetings = updated
    }

    func fetch(id: UUID) -> Meeting? {
        allMeetings.first { $0.id == id }
    }

    func delete(id: UUID) {
        let fileURL = storageDirectory.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: fileURL)
        allMeetings.removeAll { $0.id == id }
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

        // Meetings with no notes and no error were interrupted mid-processing (app crash/force-quit).
        // Mark them failed so the UI shows an error state instead of an infinite spinner.
        for i in meetings.indices where meetings[i].notes == nil && meetings[i].notesGenerationError == nil {
            meetings[i].notesGenerationError = "Processing was interrupted. Delete and re-record to try again."
            let fileURL = storageDirectory.appendingPathComponent("\(meetings[i].id.uuidString).json")
            if let data = try? encoder.encode(meetings[i]) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }

        allMeetings = meetings
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/meetings")
    }
}
