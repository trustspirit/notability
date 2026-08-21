import XCTest
import AVFoundation
import Speech
@testable import Notability

/// Covers the state-management layer that sits between the realtime audio
/// threads calling `LiveTranscriptionService.append(_:)` and the async contexts
/// running `prepare`/`finish`. `SpeechAnalyzer` itself needs model assets and
/// real capture hardware, but this layer is plain Swift and fully testable.
final class AnalyzerInputSinkTests: XCTestCase {
    private let captureFormat = AudioFixtures.format

    private func drain(_ stream: AsyncStream<AnalyzerInput>) -> Task<[AnalyzerInput], Never> {
        Task {
            var received: [AnalyzerInput] = []
            for await input in stream { received.append(input) }
            return received
        }
    }

    private func tagged(_ count: Int, seconds: Double = 0.032) -> [TaggedAudioBuffer] {
        var clock = FrameClock(sampleRate: captureFormat.sampleRate)
        return (0..<count).map { _ in
            let buffer = AudioFixtures.tone(seconds: seconds)
            return TaggedAudioBuffer(
                source: .microphone,
                buffer: buffer,
                startTime: clock.advance(by: buffer.frameLength)
            )
        }
    }

    // MARK: - Sink

    func test_passes_buffers_through_untouched_when_no_conversion_is_needed() async {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation)
        let collector = drain(stream)

        let items = tagged(4)
        items.forEach(sink.send)
        sink.finish()

        let received = await collector.value
        XCTAssertEqual(received.count, items.count)
        for (index, input) in received.enumerated() {
            XCTAssertTrue(input.buffer === items[index].buffer, "buffer \(index) was copied or reordered")
        }
    }

    func test_resamples_every_buffer_when_the_analyzer_wants_another_format() async {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AnalyzerInputSink(targetFormat: target, continuation: continuation)
        let collector = drain(stream)

        let items = tagged(10)
        items.forEach(sink.send)
        sink.finish()

        let received = await collector.value
        XCTAssertFalse(received.isEmpty)
        XCTAssertTrue(
            received.allSatisfy { $0.buffer.format.isEqual(target) },
            "every buffer must arrive in the format the analyzer advertised"
        )

        // A converter that terminates after its first buffer still produces
        // plausible-looking output, so assert on the whole stream: 16 kHz in,
        // 48 kHz out means three times the frames, minus resampler priming.
        let inputFrames = items.reduce(0) { $0 + Int($1.buffer.frameLength) }
        let outputFrames = received.reduce(0) { $0 + Int($1.buffer.frameLength) }
        XCTAssertEqual(Double(outputFrames), Double(inputFrames) * 3, accuracy: 3 * 512)
    }

    func test_stamps_each_buffer_with_the_frame_derived_start_time() async {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation)
        let collector = drain(stream)

        let items = tagged(6)
        items.forEach(sink.send)
        sink.finish()

        let received = await collector.value
        XCTAssertEqual(received.count, items.count)
        for (index, input) in received.enumerated() {
            XCTAssertEqual(
                input.bufferStartTime?.seconds ?? .nan,
                items[index].startTime,
                accuracy: 1e-6,
                "buffer \(index) reached the analyzer without its recording-relative start time"
            )
        }
    }

    func test_drops_empty_buffers_so_timestamps_stay_strictly_increasing() async {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation)
        let collector = drain(stream)

        let empty = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: 512)!
        empty.frameLength = 0
        sink.send(TaggedAudioBuffer(source: .microphone, buffer: empty, startTime: 0))
        let real = tagged(1)[0]
        sink.send(real)
        sink.finish()

        let received = await collector.value
        XCTAssertEqual(received.count, 1, "an empty buffer repeats the previous timestamp")
        XCTAssertTrue(received.first?.buffer === real.buffer)
    }

    func test_sending_after_finish_is_ignored() async {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let sink = AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation)
        let collector = drain(stream)

        let items = tagged(3)
        sink.send(items[0])
        sink.finish()
        sink.send(items[1])
        sink.send(items[2])

        let received = await collector.value
        XCTAssertEqual(received.count, 1, "late audio-thread callbacks must not reopen a finished sink")
    }

    // MARK: - Registry

    func test_registry_has_no_sink_for_a_source_that_was_never_prepared() {
        let registry = AnalyzerInputRegistry()
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.sink(for: .systemAudio))
    }

    func test_removeAll_hands_back_every_sink_and_empties_the_registry() {
        let registry = AnalyzerInputRegistry()
        for source in AudioSource.allCases {
            let (_, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            registry.register(
                AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation),
                for: source
            )
        }

        let removed = registry.removeAll()

        XCTAssertEqual(removed.count, AudioSource.allCases.count)
        XCTAssertTrue(registry.isEmpty)
        XCTAssertNil(registry.sink(for: .microphone))
        XCTAssertTrue(registry.removeAll().isEmpty)
    }

    func test_buffers_keep_their_order_while_the_registry_is_mutated_concurrently() async {
        let registry = AnalyzerInputRegistry()
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        registry.register(
            AnalyzerInputSink(targetFormat: captureFormat, continuation: continuation),
            for: .microphone
        )
        let collector = drain(stream)

        let items = tagged(400)
        let format = captureFormat
        let group = DispatchGroup()

        // Stands in for prepare()/finish() churning the dictionary that the
        // audio thread reads on every callback.
        DispatchQueue(label: "test.control").async(group: group) {
            for _ in 0..<items.count {
                let (_, other) = AsyncStream<AnalyzerInput>.makeStream()
                registry.register(
                    AnalyzerInputSink(targetFormat: format, continuation: other),
                    for: .systemAudio
                )
                _ = registry.sink(for: .systemAudio)
            }
        }
        DispatchQueue(label: "test.audio").async(group: group) {
            for item in items {
                registry.sink(for: item.source)?.send(item)
            }
        }
        await withCheckedContinuation { resumption in
            group.notify(queue: .global()) { resumption.resume() }
        }
        registry.removeAll().forEach { $0.finish() }

        let received = await collector.value
        XCTAssertEqual(received.count, items.count, "no buffer may be dropped")
        for (index, input) in received.enumerated() {
            XCTAssertEqual(
                input.bufferStartTime?.seconds ?? .nan,
                items[index].startTime,
                accuracy: 1e-6,
                "buffer \(index) arrived out of order"
            )
        }
    }
}
