import XCTest
import AVFoundation
import Combine
@testable import Notability

/// The relay is the only part of capture that runs without audio hardware, and
/// it owns everything that can silently corrupt a transcript: per-source
/// timestamps, delivery order, and the gate that stops late callbacks.
final class CaptureBufferRelayTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    /// Sends arrive on whatever thread called `send`, so collection has to be
    /// synchronised even though the assertions run on the test thread.
    private final class Collector {
        private let lock = NSLock()
        private var storage: [TaggedAudioBuffer] = []
        private var completionCount = 0

        var buffers: [TaggedAudioBuffer] { lock.withLock { storage } }
        var completions: Int { lock.withLock { completionCount } }

        func startTimes(of source: AudioSource) -> [TimeInterval] {
            buffers.filter { $0.source == source }.map(\.startTime)
        }

        func append(_ buffer: TaggedAudioBuffer) { lock.withLock { storage.append(buffer) } }
        func complete() { lock.withLock { completionCount += 1 } }
    }

    private func collect(from sut: CaptureBufferRelay) -> Collector {
        let collector = Collector()
        sut.bufferPublisher
            .sink(
                receiveCompletion: { _ in collector.complete() },
                receiveValue: { collector.append($0) }
            )
            .store(in: &cancellables)
        return collector
    }

    /// 0.1 s at 16 kHz, so each buffer advances its clock by exactly 1_600 frames.
    private func tenth() -> AVAudioPCMBuffer { AudioFixtures.tone(seconds: 0.1) }

    // MARK: - Gate

    func test_drops_buffers_sent_before_open() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)

        sut.send(tenth(), from: .microphone)

        XCTAssertTrue(collector.buffers.isEmpty)
    }

    func test_drops_buffers_sent_after_close() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)
        sut.open()
        sut.send(tenth(), from: .microphone)

        sut.close()
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)

        XCTAssertEqual(collector.buffers.count, 1)
    }

    func test_drops_zero_frame_buffers_so_timestamps_stay_strictly_increasing() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)
        sut.open()

        let empty = AVAudioPCMBuffer(pcmFormat: AudioFixtures.format, frameCapacity: 512)!
        empty.frameLength = 0
        sut.send(empty, from: .microphone)
        sut.send(tenth(), from: .microphone)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0])
    }

    // MARK: - Timestamps

    func test_each_source_advances_its_own_clock() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)
        sut.open()

        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)
        sut.send(tenth(), from: .microphone)

        // A single shared clock would stamp these 0, 0.1, 0.2, 0.3, 0.4 and
        // push both tracks out of sync with the recorded audio.
        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 0.1, 0.2])
        XCTAssertEqual(collector.startTimes(of: .systemAudio), [0, 0.1])
    }

    func test_open_restarts_both_clocks_at_zero() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)

        sut.open()
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)
        sut.close()

        sut.open()
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 0])
        XCTAssertEqual(collector.startTimes(of: .systemAudio), [0, 0])
    }

    // MARK: - Shared origin

    /// The defect this pins: system audio attaches seconds after the
    /// microphone, because `SCShareableContent` and `SCStream.startCapture()`
    /// both take their time. Stamping each source from its own frame zero made
    /// those two frame zeros the same index but different instants, and every
    /// consumer downstream aligns by index.
    func test_a_source_that_starts_late_is_stamped_from_the_shared_origin() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        // The microphone is attached first and delivers its first 0.1 s buffer
        // 0.1 s later, so it begins at the origin.
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        // System audio only arrives three seconds in.
        clock.advance(by: 3.0)
        sut.send(tenth(), from: .systemAudio)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0])
        XCTAssertEqual(collector.startTimes(of: .systemAudio), [3.0])
    }

    /// The two tracks stay a fixed distance apart afterwards: seeding is a
    /// one-off, and spacing within a source still comes from its frames.
    func test_the_offset_between_two_late_starting_sources_stays_constant() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        clock.advance(by: 3.0)
        sut.send(tenth(), from: .systemAudio)
        for _ in 0..<3 {
            clock.advance(by: 0.1)
            sut.send(tenth(), from: .microphone)
            sut.send(tenth(), from: .systemAudio)
        }

        let mic = collector.startTimes(of: .microphone)
        let system = collector.startTimes(of: .systemAudio)
        XCTAssertEqual(mic, [0, 0.1, 0.2, 0.3])
        XCTAssertEqual(system, [3.0, 3.1, 3.2, 3.3])
        for (micTime, systemTime) in zip(mic, system) {
            XCTAssertEqual(systemTime - micTime, 3.0, accuracy: 1e-9)
        }
    }

    /// Once a source has its origin, a stalled callback must not move its
    /// audio: the frames arrived late but they were recorded on time.
    func test_a_delayed_callback_does_not_shift_the_audio_it_carries() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        // Two buffers' worth of audio delivered in one late burst.
        clock.advance(by: 5.0)
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .microphone)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 0.1, 0.2])
    }

    // MARK: - Resynchronizing after an interruption

    /// An input-device switch restarts the engine, and the microphone delivers
    /// nothing while it does. Counting frames would splice that interval out of
    /// `mic.m4a` and slide everything after it ahead of system audio, which
    /// kept recording — and the error compounds with every switch.
    func test_a_source_resumes_where_the_clock_says_after_an_interruption() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)

        // Two seconds pass with the engine down, then the tap comes back.
        sut.resynchronize(.microphone)
        clock.advance(by: 2.0)
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 0.1, 2.2, 2.3])
    }

    /// Resynchronizing must not be able to rewind a source. A timestamp that
    /// repeated or went backwards is `audioDisordered`, which costs that source
    /// its captions for the rest of the recording.
    func test_resynchronizing_never_moves_a_timeline_backwards() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        // A source that has delivered more audio than the clock has counted —
        // which is what a burst of buffers after a slow start looks like.
        clock.advance(by: 0.1)
        for _ in 0..<10 { sut.send(tenth(), from: .microphone) }

        sut.resynchronize(.microphone)
        sut.send(tenth(), from: .microphone)

        let times = collector.startTimes(of: .microphone)
        XCTAssertEqual(times.last, 1.0)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count, "a timestamp was reused")
    }

    /// Each source is resynchronized on its own; the other's timeline is
    /// untouched, because only one of them was interrupted.
    func test_resynchronizing_one_source_leaves_the_other_alone() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)
        sut.open()

        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)

        sut.resynchronize(.microphone)
        clock.advance(by: 2.1)
        sut.send(tenth(), from: .microphone)
        sut.send(tenth(), from: .systemAudio)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 2.1])
        XCTAssertEqual(collector.startTimes(of: .systemAudio), [0, 0.1])
    }

    func test_open_moves_the_shared_origin_to_the_new_recording() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collect(from: sut)

        sut.open()
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)
        sut.close()

        // An hour of the app sitting idle between recordings must not become an
        // hour of leading silence in the next one's tracks.
        clock.advance(by: 3_600)
        sut.open()
        clock.advance(by: 0.1)
        sut.send(tenth(), from: .microphone)

        XCTAssertEqual(collector.startTimes(of: .microphone), [0, 0])
    }

    // MARK: - Publisher lifetime

    func test_buffer_publisher_never_completes_and_survives_repeated_recordings() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        // Subscribed before the first open, which is the order Task 9 is free
        // to use precisely because the subject is never replaced.
        let collector = collect(from: sut)

        sut.open()
        sut.send(tenth(), from: .microphone)
        sut.close()
        sut.open()
        sut.send(tenth(), from: .microphone)
        sut.close()

        XCTAssertEqual(collector.buffers.count, 2, "the subscription taken before the first recording went dead")
        XCTAssertEqual(collector.completions, 0, "a completed publisher cannot be reused for the next recording")
    }

    // MARK: - Levels

    func test_reports_the_rms_of_every_published_buffer() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        var levels: [Float] = []
        sut.levelPublisher.sink { levels.append($0) }.store(in: &cancellables)
        sut.open()

        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.5), from: .microphone)
        sut.send(AudioFixtures.silence(seconds: 0.1), from: .microphone)

        XCTAssertEqual(levels.count, 2)
        // RMS of a sine is its amplitude over root two.
        XCTAssertEqual(levels[0], 0.5 / Float(2).squareRoot(), accuracy: 0.01)
        XCTAssertEqual(levels[1], 0, accuracy: 1e-6)
    }

    // MARK: - Concurrency

    func test_keeps_per_source_order_when_both_sources_send_at_once() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collect(from: sut)
        sut.open()

        let perSource = 500
        let group = DispatchGroup()
        for source in AudioSource.allCases {
            DispatchQueue(label: "test.\(source.rawValue)").async(group: group) {
                for _ in 0..<perSource {
                    sut.send(AudioFixtures.tone(seconds: 0.1), from: source)
                }
            }
        }
        group.wait()

        for source in AudioSource.allCases {
            let times = collector.startTimes(of: source)
            XCTAssertEqual(times.count, perSource, "\(source) lost buffers")
            XCTAssertEqual(
                times,
                (0..<perSource).map { Double($0 * 1_600) / 16_000 },
                "\(source) buffers were stamped out of order"
            )
        }
    }

    // MARK: - Levels

    /// Levels drive the waveform, and both sources publish onto one stream. If
    /// each send replaced the last, the bar would show whichever source
    /// happened to deliver last rather than what the meeting sounds like.
    private func collectLevels(from sut: CaptureBufferRelay) -> LevelCollector {
        let collector = LevelCollector()
        sut.levelPublisher
            .sink { collector.append($0) }
            .store(in: &cancellables)
        return collector
    }

    private final class LevelCollector {
        private let lock = NSLock()
        private var storage: [Float] = []
        var values: [Float] { lock.withLock { storage } }
        var last: Float { values.last ?? -1 }
        func append(_ value: Float) { lock.withLock { storage.append(value) } }
    }

    func test_a_silent_source_does_not_pull_the_level_down() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collectLevels(from: sut)
        sut.open()

        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.5), from: .microphone)
        let afterMic = collector.last
        sut.send(AudioFixtures.silence(seconds: 0.1), from: .systemAudio)

        XCTAssertGreaterThan(afterMic, 0.1, "A loud microphone buffer should raise the level")
        XCTAssertEqual(
            collector.last,
            afterMic,
            accuracy: 0.001,
            "Silence from the other source must not erase the microphone's level"
        )
    }

    func test_the_louder_source_sets_the_level() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collectLevels(from: sut)
        sut.open()

        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.2), from: .microphone)
        let quiet = collector.last
        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.8), from: .systemAudio)

        XCTAssertGreaterThan(collector.last, quiet, "The louder source should win")
    }

    /// A source that stops delivering — a dead stream, a revoked permission —
    /// must not hold the waveform up at the level it left behind.
    func test_a_source_that_stopped_delivering_stops_counting() {
        let clock = TestMonotonicClock()
        let sut = CaptureBufferRelay(sampleRate: 16_000, clock: clock.read)
        let collector = collectLevels(from: sut)
        sut.open()

        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.8), from: .systemAudio)
        XCTAssertGreaterThan(collector.last, 0.1)

        clock.advance(by: 2.0)
        sut.send(AudioFixtures.silence(seconds: 0.1), from: .microphone)

        XCTAssertLessThan(collector.last, 0.01, "A stale level should have aged out")
    }

    func test_open_forgets_the_levels_of_the_previous_recording() {
        let sut = CaptureBufferRelay(sampleRate: 16_000)
        let collector = collectLevels(from: sut)

        sut.open()
        sut.send(AudioFixtures.tone(seconds: 0.1, amplitude: 0.8), from: .systemAudio)
        sut.close()

        sut.open()
        sut.send(AudioFixtures.silence(seconds: 0.1), from: .microphone)

        XCTAssertLessThan(collector.last, 0.01, "The new recording started from the old level")
    }
}
