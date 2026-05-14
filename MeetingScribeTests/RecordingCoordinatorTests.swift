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

    func test_stop_transitions_to_processing_then_done() async throws {
        let (sut, _, _, store) = makeSUT()
        try await sut.startRecording()
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
    func transcribe(audioURL: URL, timestamp: TimeInterval, prompt: String? = nil) async throws -> TranscriptChunk {
        TranscriptChunk(timestamp: timestamp, text: "Mock transcription")
    }
}

final class MockNoteGenerationService: NoteGenerationServiceProtocol {
    func generateNotes(transcript: [TranscriptChunk]) async throws -> MeetingNotes {
        MeetingNotes(summary: "Mock summary", actionItems: [], keyDecisions: [])
    }
}
