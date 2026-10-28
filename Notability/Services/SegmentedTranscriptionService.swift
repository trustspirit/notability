import Foundation

/// Sends a recording the diarization API would reject for its length as
/// several requests, and puts the results back together as one transcript.
///
/// The API caps a request at 1400 seconds of audio, which is about 23 minutes —
/// far short of a normal meeting — and `chunking_strategy` does not lift that
/// cap. Below the cap this changes nothing: `AudioSegmenter` hands back the mix
/// itself, and exactly one request goes out, the way it always did.
///
/// Segments go up one at a time rather than in parallel. A meeting is three or
/// four requests at most, so the wall-clock saving would be small, and doing
/// them in order means the first failure stops the rest instead of paying for
/// uploads whose transcript is already lost.
///
/// Each segment's result is saved next to the recording as soon as it comes
/// back. A meeting split three ways that fails on its third request would
/// otherwise throw away the two transcripts already paid for, and Retry would
/// pay for them again — the longer the meeting, the more likely some request
/// fails, so this is where long meetings lost the most. The saved results go
/// with the recording's directory once the meeting no longer needs it.
///
/// What splitting costs is speaker continuity: each request labels speakers
/// from scratch, so only the local speaker — named by the reference clip that
/// goes up with every request — keeps one identity across the whole meeting.
/// See `speaker(_:inSegment:)`.
final class SegmentedTranscriptionService: FinalTranscriptionServiceProtocol {
    private let inner: FinalTranscriptionServiceProtocol
    private let config: AudioSegmenter.Config

    init(
        inner: FinalTranscriptionServiceProtocol,
        config: AudioSegmenter.Config = AudioSegmenter.Config()
    ) {
        self.inner = inner
        self.config = config
    }

    func transcribe(
        audioURL: URL,
        speakerReference: Data?,
        language: String?
    ) async throws -> DiarizedTranscription {
        let workingDirectory = audioURL
            .deletingLastPathComponent()
            .appendingPathComponent("segments")
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let segments = try await AudioSegmenter.split(
            audioURL,
            into: workingDirectory,
            config: config
        )

        // A recording short enough for one request has nothing to resume.
        let cache = segments.count > 1
            ? SegmentResultCache(
                directory: audioURL.deletingLastPathComponent()
                    .appendingPathComponent(Self.resultsDirectoryName),
                segmentCount: segments.count,
                language: language,
                hasSpeakerReference: speakerReference != nil
            )
            : nil

        var chunks: [TranscriptChunk] = []
        var billedSeconds: Int?
        for (index, segment) in segments.enumerated() {
            let transcription: DiarizedTranscription
            if let saved = cache?.load(index: index, startTime: segment.startTime) {
                transcription = saved
            } else {
                // A cancellation that lands between two segments has no
                // in-flight request to kill, so nothing else would stop the
                // next upload.
                try Task.checkCancellation()
                transcription = try await inner.transcribe(
                    audioURL: segment.url,
                    speakerReference: speakerReference,
                    language: language
                )
                cache?.save(transcription, index: index, startTime: segment.startTime)
            }
            chunks += transcription.chunks.map {
                TranscriptChunk(
                    timestamp: $0.timestamp + segment.startTime,
                    text: $0.text,
                    speaker: Self.speaker($0.speaker, inSegment: index)
                )
            }
            if let seconds = transcription.billedSeconds {
                billedSeconds = (billedSeconds ?? 0) + seconds
            }
        }
        cache?.clear()
        return DiarizedTranscription(chunks: chunks, billedSeconds: billedSeconds)
    }

    /// Beside the recording rather than inside the `segments` working
    /// directory, which is deleted on every exit, failures included.
    static let resultsDirectoryName = "segment-transcripts"

    /// Diarization letters are assigned per request, so the "B" of one segment
    /// is not the "B" of the next. Numbering them by segment says that out
    /// loud instead of letting the transcript imply a continuity the API never
    /// promised.
    ///
    /// The local speaker is exempt: the same reference clip goes up with every
    /// request, so that name does mean the same person throughout.
    private static func speaker(_ speaker: String?, inSegment index: Int) -> String? {
        guard let speaker, index > 0,
              speaker != DiarizedTranscriptionService.localSpeakerName else {
            return speaker
        }
        return "\(speaker)\(index + 1)"
    }
}

/// One saved file per finished segment request.
///
/// A saved result is only reused for the same cut: the same number of
/// segments, starting at the same place, transcribed with the same language and
/// with or without a speaker reference as before. The cuts are a deterministic
/// function of the recording, so a retry of the same meeting finds them again;
/// anything else that changed means the saved text answers a different request
/// and is ignored.
///
/// Saving is best effort. A result that cannot be written costs only the
/// resume, never the transcription that produced it.
private struct SegmentResultCache {
    let directory: URL
    let segmentCount: Int
    let language: String?
    let hasSpeakerReference: Bool

    private struct Entry: Codable {
        let segmentCount: Int
        let startTime: TimeInterval
        let language: String?
        let hasSpeakerReference: Bool
        let chunks: [TranscriptChunk]
        let billedSeconds: Int?
    }

    /// Cut positions are recomputed from the decoded file, so they are compared
    /// to the millisecond rather than exactly.
    private static let startTimeTolerance: TimeInterval = 0.001

    func load(index: Int, startTime: TimeInterval) -> DiarizedTranscription? {
        guard let data = try? Data(contentsOf: url(for: index)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.segmentCount == segmentCount,
              abs(entry.startTime - startTime) < Self.startTimeTolerance,
              entry.language == language,
              entry.hasSpeakerReference == hasSpeakerReference else {
            return nil
        }
        return DiarizedTranscription(chunks: entry.chunks, billedSeconds: entry.billedSeconds)
    }

    func save(_ transcription: DiarizedTranscription, index: Int, startTime: TimeInterval) {
        let entry = Entry(
            segmentCount: segmentCount,
            startTime: startTime,
            language: language,
            hasSpeakerReference: hasSpeakerReference,
            chunks: transcription.chunks,
            billedSeconds: transcription.billedSeconds
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(for: index), options: .atomic)
    }

    /// Once the whole transcript exists the meeting stores it, and nothing will
    /// read these again.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(for index: Int) -> URL {
        directory.appendingPathComponent("segment-\(index).json")
    }
}
