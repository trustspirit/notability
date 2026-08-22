import XCTest
import AVFoundation
@testable import Notability

final class CaptureBufferRouterTests: XCTestCase {

    func test_routes_a_buffer_to_the_recorder_for_its_own_source() {
        let env = makeSUT()

        env.router.route(tagged(.microphone, seconds: 0.1, startTime: 0))

        XCTAssertEqual(env.micWriter.appendedFrameCounts, [1_600])
        XCTAssertEqual(env.systemWriter.appendedFrameCounts, [])
    }

    func test_routes_every_buffer_to_live_transcription() {
        let env = makeSUT()

        env.router.route(tagged(.microphone, seconds: 0.1, startTime: 0))
        env.router.route(tagged(.systemAudio, seconds: 0.1, startTime: 0))

        XCTAssertEqual(env.live.appendedBuffers.map(\.source), [.microphone, .systemAudio])
    }

    func test_routing_stays_on_the_calling_thread() {
        let env = makeSUT()

        let captureThread = onDedicatedThread {
            env.router.route(self.tagged(.microphone, seconds: 0.1, startTime: 0))
        }

        XCTAssertEqual(env.live.appendThreadIDs, [captureThread])
        XCTAssertEqual(env.micWriter.appendThreadIDs, [captureThread])
        XCTAssertNotEqual(captureThread, currentThreadID())
    }

    func test_a_source_with_no_recorder_still_reaches_live_transcription() {
        // SessionRecorder creation can fail per source; losing the file must not
        // cost that source its captions.
        let live = FakeLiveTranscriptionService()
        let router = CaptureBufferRouter(recorders: [:], liveTranscription: live)

        router.route(tagged(.microphone, seconds: 0.1, startTime: 0))

        XCTAssertEqual(live.appendedBuffers.count, 1)
    }

    func test_concurrent_sources_each_keep_their_own_order() {
        let env = makeSUT()
        let sources: [AudioSource] = [.microphone, .systemAudio]

        // One thread per source, which is what the capture layer provides. The
        // two threads interleave freely; only within-source order is promised.
        DispatchQueue.concurrentPerform(iterations: sources.count) { index in
            let source = sources[index]
            for step in 1...50 {
                env.router.route(
                    self.tagged(source, seconds: 0.01, startTime: Double(step))
                )
            }
        }

        for source in sources {
            let startTimes = env.live.appendedBuffers
                .filter { $0.source == source }
                .map(\.startTime)
            XCTAssertEqual(startTimes, (1...50).map(Double.init), "\(source) lost its order")
        }
    }

    // MARK: - Helpers

    private struct Environment {
        let router: CaptureBufferRouter
        let live: FakeLiveTranscriptionService
        let micWriter: FakeSessionAudioWriter
        let systemWriter: FakeSessionAudioWriter
    }

    private func makeSUT() -> Environment {
        let root = FileManager.default.temporaryDirectory
        let live = FakeLiveTranscriptionService()
        let micWriter = FakeSessionAudioWriter(url: root.appendingPathComponent("mic.m4a"))
        let systemWriter = FakeSessionAudioWriter(url: root.appendingPathComponent("system.m4a"))
        let router = CaptureBufferRouter(
            recorders: [.microphone: micWriter, .systemAudio: systemWriter],
            liveTranscription: live
        )
        return Environment(router: router, live: live, micWriter: micWriter, systemWriter: systemWriter)
    }

    private func tagged(
        _ source: AudioSource,
        seconds: Double,
        startTime: TimeInterval
    ) -> TaggedAudioBuffer {
        TaggedAudioBuffer(
            source: source,
            buffer: AudioFixtures.tone(seconds: seconds),
            startTime: startTime
        )
    }
}
