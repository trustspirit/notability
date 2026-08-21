import Foundation

struct Meeting: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var date: Date
    var durationSeconds: Double
    var transcript: [TranscriptChunk]
    var notes: MeetingNotes?
    var notesGenerationError: String?
    // Session audio lives here until note generation succeeds. Retained on any
    // failure so the user can retry without re-recording the meeting.
    var audioDirectory: URL?
    // Distinguishes a diarization failure from a note-generation failure.
    var transcriptionError: String?
    // usage.seconds reported by the transcription API, for cost display.
    var billedSeconds: Int?

    init(
        id: UUID,
        title: String,
        date: Date,
        durationSeconds: Double,
        transcript: [TranscriptChunk],
        notes: MeetingNotes?,
        notesGenerationError: String?,
        audioDirectory: URL? = nil,
        transcriptionError: String? = nil,
        billedSeconds: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.notes = notes
        self.notesGenerationError = notesGenerationError
        self.audioDirectory = audioDirectory
        self.transcriptionError = transcriptionError
        self.billedSeconds = billedSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        durationSeconds = try c.decode(Double.self, forKey: .durationSeconds)
        transcript = try c.decode([TranscriptChunk].self, forKey: .transcript)
        notes = try c.decodeIfPresent(MeetingNotes.self, forKey: .notes)
        notesGenerationError = try c.decodeIfPresent(String.self, forKey: .notesGenerationError)
        audioDirectory = try c.decodeIfPresent(URL.self, forKey: .audioDirectory)
        transcriptionError = try c.decodeIfPresent(String.self, forKey: .transcriptionError)
        billedSeconds = try c.decodeIfPresent(Int.self, forKey: .billedSeconds)
    }
}

enum RecordingState: Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    // Diarized transcription of the mixed session audio is in flight.
    case transcribing
    case generatingNotes
    case done(meetingId: UUID)
    case failed(String)
}
