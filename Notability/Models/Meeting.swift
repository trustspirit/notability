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
    /// True when processing stopped because the app did, rather than because a
    /// stage ran and returned an error.
    ///
    /// Both leave their reason in one of the error fields above, but only one of
    /// them is a failure. Calling an interruption a failure tells the user a
    /// stage ran when it never started, so the UI reads this to pick its wording.
    var processingWasInterrupted: Bool

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
        billedSeconds: Int? = nil,
        processingWasInterrupted: Bool = false
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
        self.processingWasInterrupted = processingWasInterrupted
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
        processingWasInterrupted =
            try c.decodeIfPresent(Bool.self, forKey: .processingWasInterrupted) ?? false
    }

    /// True when either processing stage failed. Both are retryable and both
    /// should look the same in a list, so callers rarely want just one.
    var hasProcessingFailure: Bool {
        transcriptionError != nil || notesGenerationError != nil
    }

    /// True when re-running the pipeline has something left to do that can
    /// still succeed. The one condition Retry is offered on, so that no message
    /// can suggest a retry the meeting cannot run.
    ///
    /// A saved transcript is enough on its own: it is the expensive half and it
    /// leaves only note generation, which needs no audio. Otherwise there has
    /// to be audio to transcribe, and `audioDirectory` is the claim on it —
    /// cleared when notes succeed, and cleared when the audio turns out to be
    /// unreadable, so a non-nil value means there is something worth reading.
    var canRetryProcessing: Bool {
        notes == nil && (!transcript.isEmpty || audioDirectory != nil)
    }
}

enum RecordingState: Equatable {
    case idle
    case recording(elapsed: TimeInterval)
    // Diarized transcription of the mixed session audio is in flight. Both
    // processing states carry the meeting id because the recording has already
    // ended by the time they are entered, so there is no "current" meeting left
    // to ask the coordinator for.
    case transcribing(meetingId: UUID)
    case generatingNotes(meetingId: UUID)
    case done(meetingId: UUID)
    case failed(String)
}
