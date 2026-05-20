import Foundation

struct Meeting: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var date: Date
    var durationSeconds: Double
    var transcript: [TranscriptChunk]
    var notes: MeetingNotes?
    var notesGenerationError: String?
}

enum RecordingState: Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    case processing
    case done(meetingId: UUID)
    case failed(String)
}
