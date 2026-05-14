import XCTest
import Combine
@testable import MeetingScribe

@MainActor
final class RecordingCoordinatorTests: XCTestCase {
    var cancellables = Set<AnyCancellable>()

    func test_start_transitions_to_recording() async throws {
        let (sut, _, _, _) = makeSUT()
        XCTAssertEqual(sut.state, .idle)
        try await sut.startRecording()
        if case .recording = sut.state { } else {
            XCTFail("Expected .recording, got \(sut.state)")
        }
    }

    func test_stop_with_no_audio_transitions_to_failed() async throws {
        let (sut, _, _, _) = makeSUT()
        try await sut.startRecording()
        await sut.stopRecording()
        // No chunks emitted → validTranscript is empty → state must be .failed
        if case .failed = sut.state { } else {
            XCTFail("Expected .failed when no audio captured, got \(sut.state)")
        }
    }

    func test_stop_with_transcript_transitions_to_done() async throws {
        let (sut, capture, _, store) = makeSUT()
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 300_000_000)
        await sut.stopRecording()

        if case .done(let id) = sut.state {
            XCTAssertNotNil(store.fetch(id: id))
        } else {
            XCTFail("Expected .done, got \(sut.state)")
        }
    }

    func test_chunks_are_transcribed_and_accumulated() async throws {
        let (sut, capture, _, _) = makeSUT()
        try await sut.startRecording()

        // chunkHandlingTask is a detached Task — yield so it starts and reaches
        // the `for await` subscription point before we emit. PassthroughSubject
        // drops values that arrive before any subscriber is listening.
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        // Allow async transcription to complete
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2s

        XCTAssertFalse(sut.liveTranscript.isEmpty)
    }

    func test_transcript_chunks_merge_until_sentence_terminates() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "그렇습니다 그래서 이게 또 전문 용어",
            "뭐가 있군요.",
            "다음 문장입니다."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 12)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 2)
        XCTAssertEqual(sut.liveTranscript[0].timestamp, 0)
        XCTAssertEqual(sut.liveTranscript[0].text, "그렇습니다 그래서 이게 또 전문 용어 뭐가 있군요.")
        XCTAssertEqual(sut.liveTranscript[1].timestamp, 12)
        XCTAssertEqual(sut.liveTranscript[1].text, "다음 문장입니다.")
    }

    func test_continuous_long_sentence_merges_across_multiple_live_chunks() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "제가 만 원에 샀어요",
            "만오천원이 됐어요",
            "그럼 이제 추적 손절매 가격이",
            "한 만삼천오백원 됐을 거 아니에요."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 12)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 18)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 1)
        XCTAssertEqual(
            sut.liveTranscript.first?.text,
            "제가 만 원에 샀어요 만오천원이 됐어요 그럼 이제 추적 손절매 가격이 한 만삼천오백원 됐을 거 아니에요."
        )
    }

    func test_unpunctuated_chunks_do_not_merge_after_long_timestamp_gap() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "첫 번째 주제 이야기",
            "두 번째 주제 이야기"
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 20)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 2)
        XCTAssertEqual(sut.liveTranscript[0].text, "첫 번째 주제 이야기")
        XCTAssertEqual(sut.liveTranscript[1].text, "두 번째 주제 이야기")
    }

    func test_live_partial_merges_with_previous_unfinished_sentence_for_display() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.text = "제가 만약에"
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        transcription.text = "만 원에 샀어요."
        transcription.partials = ["만 원에"]
        transcription.delayNanoseconds = 300_000_000
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sut.visibleLiveTranscript.count, 1)
        XCTAssertEqual(sut.visibleLiveTranscript.first?.text, "제가 만약에 만 원에")

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 1)
        XCTAssertEqual(sut.liveTranscript.first?.text, "제가 만약에 만 원에 샀어요.")
    }

    func test_partial_transcript_updates_live_caption_before_final() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.partials = ["실시간 자막"]
        transcription.delayNanoseconds = 300_000_000
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sut.livePartialTranscript?.text, "실시간 자막")
        XCTAssertTrue(sut.liveTranscript.isEmpty)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNil(sut.livePartialTranscript)
        XCTAssertEqual(sut.liveTranscript.first?.text, "Mock transcription")
    }

    func test_pending_transcription_count_updates_while_chunk_is_processing() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.delayNanoseconds = 300_000_000
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sut.pendingTranscriptionCount, 1)

        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(sut.pendingTranscriptionCount, 0)
    }

    func test_repeated_filler_transcript_is_dropped() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.text = "아. 아. 아. 아."
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(sut.liveTranscript.isEmpty)
    }

    func test_transcription_failure_includes_error_message() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.error = StubTranscriptionError(message: "Realtime rejected the session")
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.first?.text, "[transcription failed: Realtime rejected the session]")
    }

    // MARK: - Helpers

    private func makeSUT() -> (RecordingCoordinator, MockAudioCaptureService, MockTranscriptionService, MeetingStore) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let store = MeetingStore(storageDirectory: tempDir)
        let capture = MockAudioCaptureService()
        let transcription = MockTranscriptionService()
        let noteGen = MockNoteGenerationService()
        let sut = RecordingCoordinator(audioCapture: capture, transcription: transcription, noteGeneration: noteGen, store: store)
        return (sut, capture, transcription, store)
    }

    private func emitTempChunk(_ capture: MockAudioCaptureService, timestamp: TimeInterval) throws {
        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: timestamp))
    }
}

// MARK: - Mocks

final class MockAudioCaptureService: AudioCaptureServiceProtocol {
    private let subject = PassthroughSubject<(url: URL, timestamp: TimeInterval), Never>()
    var chunkPublisher: AnyPublisher<(url: URL, timestamp: TimeInterval), Never> { subject.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { Empty().eraseToAnyPublisher() }
    var startCalled = false
    var stopCalled = false

    func startCapture() async throws { startCalled = true }
    func stopCapture() async {
        stopCalled = true
        subject.send(completion: .finished)
    }
    func emit(_ chunk: (url: URL, timestamp: TimeInterval)) { subject.send(chunk) }
}

final class MockTranscriptionService: TranscriptionServiceProtocol {
    var text = "Mock transcription"
    var texts: [String] = []
    var error: Error?
    var partials: [String] = []
    var delayNanoseconds: UInt64 = 0

    func transcribe(
        audioURL: URL,
        timestamp: TimeInterval,
        prompt: String?,
        onPartialTranscript: TranscriptionPartialHandler?
    ) async throws -> TranscriptChunk {
        if let error { throw error }
        for partial in partials {
            await onPartialTranscript?(partial)
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let responseText = texts.isEmpty ? text : texts.removeFirst()
        return TranscriptChunk(timestamp: timestamp, text: responseText)
    }
}

struct StubTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class MockNoteGenerationService: NoteGenerationServiceProtocol {
    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes {
        MeetingNotes(summary: "Mock summary", actionItems: [], keyDecisions: [])
    }
}
