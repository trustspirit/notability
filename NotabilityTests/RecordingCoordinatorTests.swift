import XCTest
import Combine
@testable import Notability

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

    func test_completed_transcript_is_persisted_before_stop_recording() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = MeetingStore(storageDirectory: tempDir)
        let capture = MockAudioCaptureService()
        let transcription = MockTranscriptionService()
        let noteGen = MockNoteGenerationService()
        let sut = RecordingCoordinator(audioCapture: capture, transcription: transcription, noteGeneration: noteGen, store: store)

        try await sut.startRecording()
        await Task.yield()
        let meetingId = try XCTUnwrap(sut.currentMeetingId)

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)

        let reloadedStore = MeetingStore(storageDirectory: tempDir)
        XCTAssertEqual(reloadedStore.fetch(id: meetingId)?.transcript.first?.text, "Mock transcription")

        await sut.stopRecording()
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

    func test_exact_duplicate_transcript_chunk_is_dropped_within_merge_window() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "다음 안건입니다.",
            "다음 안건입니다."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 1)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 1)
        XCTAssertEqual(sut.liveTranscript.first?.text, "다음 안건입니다.")
    }

    func test_overlapping_transcript_chunk_prefix_is_not_repeated() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "오늘 회의는 예산 검토",
            "예산 검토부터 시작하겠습니다."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 1)
        XCTAssertEqual(sut.liveTranscript.first?.text, "오늘 회의는 예산 검토부터 시작하겠습니다.")
    }

    func test_overlapping_english_chunk_with_case_and_punctuation_diff_is_deduplicated() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "Let's talk about the budget review",
            "Budget review, starts now."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(sut.liveTranscript.count, 1)
        XCTAssertEqual(
            sut.liveTranscript.first?.text,
            "Let's talk about the budget review, starts now."
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

    func test_previous_transcript_is_not_fed_back_as_prompt() async throws {
        // Feeding the rolling transcript as the Whisper/gpt-4o-transcribe `prompt`
        // makes generative transcription models echo it back, producing the
        // duplicated-paragraph transcripts users reported. Every chunk must be
        // transcribed with no prompt so nothing can be regurgitated.
        let (sut, capture, transcription, _) = makeSUT()
        transcription.texts = [
            "첫 번째 문장입니다.",
            "두 번째 문장입니다."
        ]
        try await sut.startRecording()
        await Task.yield()

        try emitTempChunk(capture, timestamp: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        try emitTempChunk(capture, timestamp: 6)
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(transcription.receivedPrompts.count, 2)
        XCTAssertTrue(
            transcription.receivedPrompts.allSatisfy { $0 == nil },
            "Expected no prompt to be sent, got: \(transcription.receivedPrompts)"
        )
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

    func test_transcription_backpressure_limits_active_work_for_burst() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.delayNanoseconds = 500_000_000
        try await sut.startRecording()
        await Task.yield()

        for index in 0..<10 {
            try emitTempChunk(capture, timestamp: TimeInterval(index))
        }

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(transcription.startedCount, 4)
        XCTAssertEqual(sut.pendingTranscriptionCount, 4)

        await sut.stopRecording()

        XCTAssertEqual(transcription.startedCount, 10)
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

    func test_corrupted_audio_400_is_dropped_from_live_transcript() async throws {
        let (sut, capture, transcription, _) = makeSUT()
        transcription.error = TranscriptionService.APIError.httpError(
            400,
            "Audio file might be corrupted or unsupported. Check the selected model and language settings."
        )
        try await sut.startRecording()
        await Task.yield()

        let tempWAV = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data().write(to: tempWAV)
        capture.emit((url: tempWAV, timestamp: 0))

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(sut.liveTranscript.isEmpty)
    }

    func test_start_recording_fails_when_microphone_is_not_capturing() async throws {
        let (sut, capture, _, store) = makeSUT()
        capture.isCapturingSystemAudio = true
        capture.isCapturingMicrophone = false

        do {
            try await sut.startRecording()
            XCTFail("Expected recording to fail without microphone capture")
        } catch {
            XCTAssertTrue(store.allMeetings.isEmpty)
        }
    }

    func test_system_audio_availability_updates_while_recording() async throws {
        let (sut, capture, _, _) = makeSUT()
        try await sut.startRecording()

        XCTAssertTrue(sut.systemAudioAvailable)

        capture.isCapturingSystemAudio = false
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(sut.systemAudioAvailable)

        await sut.stopRecording()
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

final class AudioCaptureServiceTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func test_systemAudioStopDoesNotCompleteChunkPublisher() async {
        let sut = AudioCaptureService()
        let completed = expectation(description: "chunk publisher should remain open")
        completed.isInverted = true

        sut.chunkPublisher
            .sink(
                receiveCompletion: { _ in completed.fulfill() },
                receiveValue: { _ in }
            )
            .store(in: &cancellables)

        sut.handleSystemAudioCaptureStopped()

        await fulfillment(of: [completed], timeout: 0.1)
    }
}

// MARK: - Mocks

final class MockAudioCaptureService: AudioCaptureServiceProtocol {
    private let subject = PassthroughSubject<AudioChunk, Never>()
    private let systemAudioAvailabilitySubject = CurrentValueSubject<Bool, Never>(true)
    var chunkPublisher: AnyPublisher<AudioChunk, Never> { subject.eraseToAnyPublisher() }
    var audioLevelPublisher: AnyPublisher<Float, Never> { Empty().eraseToAnyPublisher() }
    var systemAudioAvailabilityPublisher: AnyPublisher<Bool, Never> {
        systemAudioAvailabilitySubject.eraseToAnyPublisher()
    }
    var isCapturingSystemAudio = true {
        didSet { systemAudioAvailabilitySubject.send(isCapturingSystemAudio) }
    }
    var isCapturingMicrophone = true
    var startCalled = false
    var stopCalled = false

    func startCapture() async throws { startCalled = true }
    func stopCapture() async {
        stopCalled = true
        subject.send(completion: .finished)
    }
    func emit(_ chunk: AudioChunk) { subject.send(chunk) }
}

final class MockTranscriptionService: TranscriptionServiceProtocol {
    var text = "Mock transcription"
    var texts: [String] = []
    var error: Error?
    var partials: [String] = []
    var delayNanoseconds: UInt64 = 0
    private(set) var startedCount = 0
    private(set) var receivedPrompts: [String?] = []

    func transcribe(
        audioURL: URL,
        timestamp: TimeInterval,
        prompt: String?,
        onPartialTranscript: TranscriptionPartialHandler?
    ) async throws -> TranscriptChunk {
        startedCount += 1
        receivedPrompts.append(prompt)
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
