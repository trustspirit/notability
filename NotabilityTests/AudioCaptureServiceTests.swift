import XCTest
import AVFoundation
import Combine
import os
@testable import Notability

/// Starting real capture needs microphone and screen-recording permission plus
/// a physical input device, so what is covered here is the part that does not:
/// the format the whole pipeline is pinned to, the state a caller reads before
/// and after a recording, the publisher lifetime Task 9 depends on, and the
/// callback surface staying off the main actor. The buffer path itself is
/// covered by `CaptureBufferRelayTests`.
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

    /// The service is main-actor isolated so its three writers of `engine`
    /// cannot interleave, but ScreenCaptureKit calls its delegate synchronously
    /// on its own queue and cannot wait for an actor hop. Blocking the main
    /// thread for the whole callback is what makes that a claim rather than a
    /// hope: a path that needed the main actor could not finish here.
    func test_the_stream_delegate_runs_to_completion_with_the_main_thread_blocked() {
        let sut = AudioCaptureService()
        let observed = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let finished = DispatchSemaphore(value: 0)

        Thread.detachNewThread {
            sut.handleSystemAudioCaptureStopped()
            // Read on the delegate's own thread: the recording layer decides
            // whether to show the "System audio unavailable" banner from this
            // getter, so it has to be true before the callback returns rather
            // than once some queue drains.
            observed.withLock { $0 = sut.isCapturingSystemAudio }
            finished.signal()
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 5),
            .success,
            "the stream delegate did not complete while the main thread was blocked"
        )
        XCTAssertEqual(observed.withLock { $0 }, false)
    }
}
