import AVFoundation
import XCTest
@testable import Notability

final class SegmentedTranscriptionServiceTests: XCTestCase {
    private var directory: URL!
    private var source: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentedTranscriptionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        source = directory.appendingPathComponent("mixed.m4a")
        // 15 seconds against the scaled-down config below splits into three.
        try AudioFixtures.writeTrack(AudioFixtures.tone(seconds: 15), to: source)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testTimestampsAreMovedOntoTheRecordingTimeline() async throws {
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 1, "one")),
            .success(transcription(at: 1, "two")),
            .success(transcription(at: 1, "three"))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        let merged = try await service.transcribe(
            audioURL: source,
            speakerReference: nil,
            language: nil
        )

        XCTAssertEqual(merged.chunks.map(\.text), ["one", "two", "three"])
        // Each segment reports its own timestamps from zero, so the second
        // segment's "1 second in" is 6 seconds into the meeting.
        for (chunk, expected) in zip(merged.chunks, [1.0, 6.0, 11.0]) {
            XCTAssertEqual(chunk.timestamp, expected, accuracy: 0.2)
        }
    }

    func testSpeakerLettersAreNamespacedPerSegmentExceptTheLocalSpeaker() async throws {
        // Each request labels speakers from scratch, so the second segment's
        // "A" is not the first segment's "A". Only the local speaker carries
        // across, because the same reference clip names them every time.
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one", speaker: "A")),
            .success(transcription(at: 0, "two", speaker: "A")),
            .success(transcription(at: 0, "three", speaker: DiarizedTranscriptionService.localSpeakerName))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        let merged = try await service.transcribe(
            audioURL: source,
            speakerReference: nil,
            language: nil
        )

        XCTAssertEqual(merged.chunks.map(\.speaker), ["A", "A2", DiarizedTranscriptionService.localSpeakerName])
    }

    func testBilledSecondsAreSummedAcrossSegments() async throws {
        // Cost display has to cover the whole meeting, not the last segment.
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one", billedSeconds: 5)),
            .success(transcription(at: 0, "two", billedSeconds: 5)),
            .success(transcription(at: 0, "three", billedSeconds: 3))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        let merged = try await service.transcribe(
            audioURL: source,
            speakerReference: nil,
            language: nil
        )

        XCTAssertEqual(merged.billedSeconds, 13)
    }

    func testCancellationBetweenSegmentsStopsBeforeTheNextRequest() async throws {
        // An in-flight request dies with the URL session, but a cancellation
        // that lands between two segments has nothing to trip over. Without a
        // check, the next segment is uploaded and billed after the user has
        // already given up on it.
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one")),
            .success(transcription(at: 0, "two")),
            .success(transcription(at: 0, "three"))
        ])
        inner.onCall = { withUnsafeCurrentTask { $0?.cancel() } }
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        let task = Task {
            try await service.transcribe(audioURL: source, speakerReference: nil, language: nil)
        }

        do {
            _ = try await task.value
            XCTFail("expected the cancelled transcription to throw")
        } catch is CancellationError {
            XCTAssertEqual(inner.callCount, 1)
        }
    }

    func testAFailedSegmentStopsTheRemainingUploads() async throws {
        // The meeting fails as a whole either way, so uploading the rest would
        // only spend money on a transcript nobody gets.
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one")),
            .failure(TestError.segmentFailed),
            .success(transcription(at: 0, "three"))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        do {
            _ = try await service.transcribe(audioURL: source, speakerReference: nil, language: nil)
            XCTFail("expected the failed segment to fail the transcription")
        } catch {
            XCTAssertEqual(inner.callCount, 2)
        }
    }

    func testEverySegmentCarriesTheSpeakerReferenceAndLanguage() async throws {
        // The reference is what keeps the local speaker's name the same across
        // segments; a segment sent without it loses that name for its whole
        // stretch of the meeting.
        let reference = Data([1, 2, 3])
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one")),
            .success(transcription(at: 0, "two")),
            .success(transcription(at: 0, "three"))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        _ = try await service.transcribe(audioURL: source, speakerReference: reference, language: "ko")

        XCTAssertEqual(inner.receivedReferences, [reference, reference, reference])
        XCTAssertEqual(inner.receivedLanguages, ["ko", "ko", "ko"])
    }

    func testSegmentFilesAreDeletedOnceTheUploadsAreDone() async throws {
        let inner = SequencedTranscriptionService(results: [
            .success(transcription(at: 0, "one")),
            .success(transcription(at: 0, "two")),
            .success(transcription(at: 0, "three"))
        ])
        let service = SegmentedTranscriptionService(inner: inner, config: testConfig())

        _ = try await service.transcribe(audioURL: source, speakerReference: nil, language: nil)

        let segmentsDirectory = directory.appendingPathComponent("segments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: segmentsDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the mix itself must survive")
    }

    private enum TestError: Error {
        case segmentFailed
    }

    private func transcription(
        at timestamp: TimeInterval,
        _ text: String,
        speaker: String? = nil,
        billedSeconds: Int? = nil
    ) -> DiarizedTranscription {
        DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: timestamp, text: text, speaker: speaker)],
            billedSeconds: billedSeconds
        )
    }

    private func testConfig() -> AudioSegmenter.Config {
        var config = AudioSegmenter.Config()
        config.requestLimit = 8
        config.targetDuration = 6
        config.searchWindow = 1
        return config
    }
}

/// Hands back one prepared result per call, so a test can say what each
/// segment's request returns.
private final class SequencedTranscriptionService: FinalTranscriptionServiceProtocol {
    private var results: [Result<DiarizedTranscription, Error>]
    private(set) var receivedURLs: [URL] = []
    private(set) var receivedReferences: [Data?] = []
    private(set) var receivedLanguages: [String?] = []

    /// Runs before each call's result is handed back, so a test can act at a
    /// known point in the sequence.
    var onCall: (() -> Void)?

    init(results: [Result<DiarizedTranscription, Error>]) {
        self.results = results
    }

    var callCount: Int { receivedURLs.count }

    func transcribe(
        audioURL: URL,
        speakerReference: Data?,
        language: String?
    ) async throws -> DiarizedTranscription {
        receivedURLs.append(audioURL)
        receivedReferences.append(speakerReference)
        receivedLanguages.append(language)
        onCall?()
        guard !results.isEmpty else {
            throw NSError(domain: "SequencedTranscriptionService", code: 0)
        }
        return try results.removeFirst().get()
    }
}
