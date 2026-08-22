import XCTest
import Combine
import os
@testable import Notability

/// A real `SCStream` needs Screen Recording permission and a display, so the
/// start/death race cannot be staged against one. Everything that decides the
/// outcome is stream identity, though, which any object has — so every ordering
/// the three transitions can arrive in is exercised here against plain objects.
final class SystemAudioOwnershipTests: XCTestCase {
    private var cancellables = Set<AnyCancellable>()

    /// Stands in for an `SCStream`. Only its identity is ever consulted.
    private final class StubStream: @unchecked Sendable {}

    /// Availability lands on the main queue from whichever thread transitioned,
    /// so collecting it needs a lock even though the assertions run on the test
    /// thread.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Bool] = []

        var values: [Bool] { lock.withLock { storage } }
        func append(_ value: Bool) { lock.withLock { storage.append(value) } }
    }

    private func collect(from sut: SystemAudioOwnership<StubStream>) -> Collector {
        let collector = Collector()
        sut.availabilityPublisher.sink { collector.append($0) }.store(in: &cancellables)
        return collector
    }

    func test_starts_not_running() {
        let sut = SystemAudioOwnership<StubStream>()

        XCTAssertFalse(sut.isRunning)
        XCTAssertNil(sut.take())
    }

    /// The defect. ScreenCaptureKit is handed `self` as delegate when the stream
    /// is constructed, so it can report the stream dead while
    /// `SCStream.startCapture()` is still returning. The start then finishes and
    /// used to announce a stream that was already gone, leaving the recording
    /// claiming to capture the far end while only the microphone ran.
    func test_a_start_that_finishes_after_its_stream_died_does_not_report_it_running() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let stream = StubStream()

        sut.claim(stream)
        sut.release(stream)
        sut.markRunning(stream)

        XCTAssertFalse(sut.isRunning)
        await drainMainQueue()
        XCTAssertEqual(collector.values, [false], "the dead stream was announced as running")
    }

    func test_a_stream_that_dies_after_being_announced_is_reported_stopped() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let stream = StubStream()

        sut.claim(stream)
        sut.markRunning(stream)
        XCTAssertTrue(sut.isRunning)

        sut.release(stream)

        XCTAssertFalse(sut.isRunning)
        await drainMainQueue()
        XCTAssertEqual(collector.values, [false, true, false])
    }

    /// A previous recording's stream reporting itself dead must not take down
    /// the recording that is running now.
    func test_a_stream_that_is_no_longer_owned_cannot_report_the_current_one_stopped() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let old = StubStream()
        let current = StubStream()

        sut.claim(old)
        sut.claim(current)
        sut.markRunning(current)

        sut.release(old)

        XCTAssertTrue(sut.isRunning, "an unowned stream's death stopped the current one")
        await drainMainQueue()
        XCTAssertEqual(collector.values, [false, true])
    }

    /// Symmetrically: a start belonging to a superseded stream must not announce
    /// the one that replaced it.
    func test_a_superseded_stream_cannot_report_itself_running() {
        let sut = SystemAudioOwnership<StubStream>()
        let old = StubStream()

        sut.claim(old)
        sut.claim(StubStream())
        sut.markRunning(old)

        XCTAssertFalse(sut.isRunning)
    }

    func test_take_hands_the_stream_back_and_reports_it_stopped() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let stream = StubStream()
        sut.claim(stream)
        sut.markRunning(stream)

        XCTAssertIdentical(sut.take(), stream)

        XCTAssertFalse(sut.isRunning)
        XCTAssertNil(sut.take(), "the stream was handed back twice")
        await drainMainQueue()
        XCTAssertEqual(collector.values, [false, true, false])
    }

    /// Only real changes are published, so a subscriber does not see a stream
    /// being claimed or a stop repeated.
    func test_only_changes_are_published() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let stream = StubStream()

        sut.claim(stream)
        sut.markRunning(stream)
        sut.markRunning(stream)
        sut.release(stream)
        sut.releaseAny()

        await drainMainQueue()
        XCTAssertEqual(collector.values, [false, true, false])
    }

    /// The transitions are ordered by the lock; the sends have to be ordered the
    /// same way. Enqueuing after releasing the lock lets the two threads here
    /// transition in one order and publish in the other, which strands the
    /// publisher on a value the getter disagrees with — and the publisher is
    /// what the "System audio unavailable" banner follows, so the recording
    /// would go on claiming to capture the far end.
    func test_concurrent_transitions_are_published_in_the_order_they_happened() async {
        let sut = SystemAudioOwnership<StubStream>()
        let collector = collect(from: sut)
        let stream = StubStream()

        // One thread is the start path announcing the stream, the other is
        // ScreenCaptureKit reporting it dead.
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            for _ in 0..<2_000 {
                if worker == 0 {
                    sut.claim(stream)
                    sut.markRunning(stream)
                } else {
                    sut.release(stream)
                }
            }
        }

        // Every send was enqueued before the last transition returned, so one
        // drain delivers all of them.
        await drainMainQueue()
        let published = collector.values

        // Only real changes are published, so the transitions alternate by
        // construction. Two equal values next to each other therefore mean two
        // sends arrived in the opposite order to the transitions that caused
        // them — and one transposition anywhere is enough to strand the final
        // value on the wrong side.
        let transposed = zip(published, published.dropFirst()).enumerated()
            .first { $0.element.0 == $0.element.1 }
        XCTAssertNil(
            transposed.map { "index \($0.offset) of \(published.count)" },
            "availability was published out of the order it changed in"
        )
        XCTAssertEqual(
            published.last,
            sut.isRunning,
            "the publisher and the getter ended up disagreeing about system audio"
        )
    }
}
