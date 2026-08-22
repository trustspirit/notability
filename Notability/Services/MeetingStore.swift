import Foundation
import Combine

/// Owns everything a meeting occupies on disk: its JSON record and the session
/// audio that belongs to it.
///
/// The audio is here rather than only in the recording layer because the two
/// have the same lifetime. Audio is kept until note generation succeeds so a
/// failure can be retried, which means the only things that can decide it is no
/// longer needed are "the notes exist" and "the meeting is gone" — and this type
/// is what knows the second one.
final class MeetingStore: ObservableObject, MeetingStoreProtocol {
    @Published private(set) var allMeetings: [Meeting] = []
    var allMeetingsPublisher: AnyPublisher<[Meeting], Never> { $allMeetings.eraseToAnyPublisher() }

    private let storageDirectory: URL
    private let audioRootDirectory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    // Serializes disk writes so two saves for the same meeting cannot interleave
    // and leave a partially written file behind.
    private let diskWriteQueue = DispatchQueue(label: "com.notability.MeetingStore.disk", qos: .utility)

    init(
        storageDirectory: URL = MeetingStore.defaultDirectory,
        audioRootDirectory: URL = MeetingStore.defaultAudioDirectory
    ) {
        self.storageDirectory = storageDirectory
        self.audioRootDirectory = audioRootDirectory
        Self.migrateLegacyStorageIfNeeded(target: storageDirectory)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        // Conditional on the load having actually read the records. The sweep
        // decides what to delete from the claims those records carry, so loading
        // nothing because the directory could not be read would make every
        // meeting's audio look unclaimed and delete all of it.
        if loadAll() {
            reclaimOrphanedAudio()
        }
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

        // sync: callers expect the meeting to be on disk when save() returns.
        diskWriteQueue.sync {
            writeMeetingToDisk(meeting)
        }
    }

    func fetch(id: UUID) -> Meeting? {
        allMeetings.first { $0.id == id }
    }

    /// Applies `transform` to the stored copy of a meeting, or does nothing if
    /// it has been deleted.
    ///
    /// The post-processing pipeline holds a meeting across minutes of network
    /// I/O — a 600 second timeout and up to five attempts per stage — and the
    /// detail view's title field is on screen for all of it. Saving the copy it
    /// read at the start reverted a rename made in between, with nothing on
    /// screen to say it had happened. Callers that suspend mutate through this
    /// instead, so they only ever write the fields they own.
    func update(id: UUID, _ transform: (inout Meeting) -> Void) {
        guard var meeting = fetch(id: id) else { return }
        transform(&meeting)
        save(meeting)
    }

    func rename(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        update(id: id) { $0.title = trimmed }
    }

    func toggleActionItemCompleted(meetingId: UUID, itemId: UUID) {
        update(id: meetingId) { meeting in
            guard let index = meeting.notes?.actionItems.firstIndex(where: { $0.id == itemId })
            else { return }
            meeting.notes?.actionItems[index].isCompleted.toggle()
        }
    }

    /// Removes the meeting and everything on disk that belongs to it.
    ///
    /// The audio goes with the record. It is only kept so a failed run can be
    /// retried, and a deleted meeting will never be retried; leaving it behind
    /// cost roughly 33 MB per recorded hour that nothing would ever reclaim.
    func delete(id: UUID) {
        let recordURL = storageDirectory.appendingPathComponent("\(id.uuidString).json")
        // The recorded location and the conventional one. They are normally the
        // same; they differ when the meeting's claim was already cleared and a
        // directory was left behind, which is still this meeting's to remove.
        let audioDirectories = Set(
            [fetch(id: id)?.audioDirectory, audioRootDirectory.appendingPathComponent(id.uuidString)]
                .compactMap { $0?.standardizedFileURL }
        )
        diskWriteQueue.sync {
            try? FileManager.default.removeItem(at: recordURL)
            for directory in audioDirectories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        allMeetings.removeAll { $0.id == id }
    }

    private func writeMeetingToDisk(_ meeting: Meeting) {
        let fileURL = storageDirectory.appendingPathComponent("\(meeting.id.uuidString).json")
        do {
            let data = try encoder.encode(meeting)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[MeetingStore] Failed to persist meeting \(meeting.id): \(error)")
        }
    }

    /// Returns false when the stored records could not be listed at all, which
    /// is not the same as there being none of them.
    private func loadAll() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }
        var meetings = contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in try? decoder.decode(Meeting.self, from: Data(contentsOf: url)) }
            .sorted { $0.date > $1.date }

        // A meeting with no notes and no recorded failure was interrupted
        // mid-processing: a crash, a force quit, or quitting a stage that had no
        // chance to write down why it stopped. It is marked so the UI shows an
        // error state rather than an endless spinner, but what it is marked with
        // depends on how far it got and on whether its audio can still be read.
        // See `interruption(for:)`.
        for index in meetings.indices {
            guard let interruption = interruption(for: meetings[index]) else { continue }
            Self.apply(interruption, to: &meetings[index])
            let meeting = meetings[index]
            diskWriteQueue.sync { writeMeetingToDisk(meeting) }
        }

        allMeetings = meetings
        return true
    }

    /// How far an interrupted meeting got, which is what decides both what it
    /// tells the user to do and whether its audio is still worth keeping.
    private enum Interruption {
        /// Stopped before the paid pass, with audio that reads.
        case beforeTranscription
        /// Stopped after the paid pass. The transcript is saved and paid for.
        case beforeNotes
        /// Stopped before the paid pass, leaving audio nothing will decode.
        case withUnreadableAudio
        /// Stopped before the paid pass with no audio to show for it.
        case withoutAudio
    }

    private func interruption(for meeting: Meeting) -> Interruption? {
        guard meeting.notes == nil,
              meeting.notesGenerationError == nil,
              meeting.transcriptionError == nil else { return nil }
        // Checked before the audio, because a meeting that got this far has
        // already been transcribed and charged for and needs no audio to
        // finish. Telling that user their meeting was never transcribed is the
        // one thing this branch exists to stop.
        guard meeting.transcript.isEmpty else { return .beforeNotes }
        guard let directory = meeting.audioDirectory else { return .withoutAudio }
        switch RecordedSessionAudio.inspect(directory: directory) {
        case .usable: return .beforeTranscription
        case .unreadable: return .withUnreadableAudio
        case .empty: return .withoutAudio
        }
    }

    private static func apply(_ interruption: Interruption, to meeting: inout Meeting) {
        // Every one of these stopped because the app did, not because a stage
        // ran and returned an error, and the UI words itself differently for the
        // two.
        meeting.processingWasInterrupted = true
        switch interruption {
        case .beforeTranscription:
            meeting.transcriptionError = ProcessingStatusMessage.interruptedBeforeTranscription
        case .beforeNotes:
            // Recorded against the notes stage because that is the stage that
            // did not finish. It is also what makes the detail view say so
            // instead of claiming the transcription failed, and what leaves the
            // transcript in place so Retry skips the paid pass.
            meeting.notesGenerationError = ProcessingStatusMessage.interruptedBeforeNotes
        case .withUnreadableAudio:
            meeting.transcriptionError = ProcessingStatusMessage.unreadableAudio
            // Dropping the claim is what withdraws the Retry offer that could
            // never have succeeded, and what lets the sweep below reclaim the
            // files. See `Meeting.canRetryProcessing`.
            meeting.audioDirectory = nil
        case .withoutAudio:
            meeting.transcriptionError = ProcessingStatusMessage.missingAudio
            meeting.audioDirectory = nil
        }
    }

    /// Deletes audio directories that no meeting refers to any more.
    ///
    /// Audio is deleted when notes succeed and when a meeting is deleted, and
    /// neither of those runs if the process dies first. Every crash and force
    /// quit therefore left a directory behind that nothing would ever reclaim,
    /// and this is the only thing that gets those back.
    ///
    /// What keeps it away from audio a meeting is still waiting on is that
    /// `Meeting.audioDirectory` is the claim on the files, and it is only
    /// cleared where the audio has genuinely stopped being needed: after notes
    /// are written, and in `apply(_:to:)` above where the audio was found
    /// unreadable. A meeting part-way through the pipeline, or sitting on a
    /// failure waiting for Retry, still holds its claim and is skipped.
    ///
    /// Called only from `init`, after `loadAll`, and that ordering is what makes
    /// it safe rather than lucky. A recording creates its directory a moment
    /// before it saves the meeting that claims it, so a sweep running alongside
    /// one could delete audio that is being written. Nothing can be recording
    /// while the store that holds the recordings is still being constructed.
    private func reclaimOrphanedAudio() {
        let claimed = Set(allMeetings.compactMap { $0.audioDirectory?.lastPathComponent })
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: audioRootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        for entry in entries {
            let name = entry.lastPathComponent
            // Matched on the directory name rather than the full path, so a
            // claim recorded under a different container path — an app moved, a
            // home directory renamed — is still recognised as a claim. The name
            // is the meeting's id, which is what makes that sound.
            guard !claimed.contains(name), UUID(uuidString: name) != nil else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            guard isDirectory == true else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notability/meetings")
    }

    /// Session audio lives beside the meeting JSON, in its own subdirectory, and
    /// is deleted once note generation succeeds, once the meeting is deleted, or
    /// once a launch finds it belongs to neither.
    static let defaultAudioDirectory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notability")
            .appendingPathComponent("audio")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
