import XCTest
import AVFoundation
import Combine
@testable import Notability

/// Starting real capture needs microphone and screen-recording permission plus
/// a physical input device, so what is covered here is the part that does not:
/// the format the whole pipeline is pinned to, the state a caller reads before
/// and after a recording, and the publisher lifetime Task 9 depends on. The
/// buffer path itself is covered by `CaptureBufferRelayTests`.
final class AudioCaptureServiceTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    func test_capture_format_is_16k_mono_int16() {
        let sut = AudioCaptureService()

        XCTAssertEqual(sut.captureFormat.sampleRate, 16_000)
        XCTAssertEqual(sut.captureFormat.channelCount, 1)
        XCTAssertEqual(sut.captureFormat.commonFormat, .pcmFormatInt16)
        XCTAssertFalse(sut.captureFormat.isInterleaved)
    }

    func test_starts_not_capturing() {
        let sut = AudioCaptureService()

        XCTAssertFalse(sut.isCapturingMicrophone)
        XCTAssertFalse(sut.isCapturingSystemAudio)
        XCTAssertFalse(sut.isEchoCancellationEnabled)
    }

    func test_a_late_subscriber_learns_that_system_audio_is_unavailable() {
        let sut = AudioCaptureService()
        var received: [Bool] = []

        sut.systemAudioAvailabilityPublisher.sink { received.append($0) }.store(in: &cancellables)

        // Replayed on subscription: the recording UI is built after capture
        // starts, so a publisher that only emitted on change would leave it
        // claiming system audio is present.
        XCTAssertEqual(received, [false])
    }

    func test_system_audio_stopping_does_not_complete_the_buffer_publisher() async {
        let sut = AudioCaptureService()
        let completed = expectation(description: "buffer publisher should remain open")
        completed.isInverted = true
        sut.bufferPublisher
            .sink(receiveCompletion: { _ in completed.fulfill() }, receiveValue: { _ in })
            .store(in: &cancellables)

        sut.handleSystemAudioCaptureStopped()

        await fulfillment(of: [completed], timeout: 0.1)
        XCTAssertFalse(sut.isCapturingSystemAudio)
    }

    func test_stopping_capture_does_not_complete_the_buffer_publisher() async {
        let sut = AudioCaptureService()
        let completed = expectation(description: "buffer publisher should remain open")
        completed.isInverted = true
        sut.bufferPublisher
            .sink(receiveCompletion: { _ in completed.fulfill() }, receiveValue: { _ in })
            .store(in: &cancellables)

        // The publisher outlives the recording so one subscription can span
        // several of them; a caller that needs to stop listening cancels.
        await sut.stopCapture()

        await fulfillment(of: [completed], timeout: 0.1)
        XCTAssertFalse(sut.isCapturingMicrophone)
        XCTAssertFalse(sut.isCapturingSystemAudio)
    }
}
