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

        var chunks: [TranscriptChunk] = []
        var billedSeconds: Int?
        for (index, segment) in segments.enumerated() {
            // A cancellation that lands between two segments has no in-flight
            // request to kill, so nothing else would stop the next upload.
            try Task.checkCancellation()
            let transcription = try await inner.transcribe(
                audioURL: segment.url,
                speakerReference: speakerReference,
                language: language
            )
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
        return DiarizedTranscription(chunks: chunks, billedSeconds: billedSeconds)
    }

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
