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
        if let data = try? encoder.encode(meeting) {
            try? data.write(to: fileURL)
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
        allMeetings = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? decoder.decode(Meeting.self, from: Data(contentsOf: url)) }
            .sorted { $0.date > $1.date }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingScribe/meetings")
    }
}
