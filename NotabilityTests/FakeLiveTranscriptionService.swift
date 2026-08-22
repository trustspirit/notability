import Foundation
import os
@testable import Notability

/// Stands in for `LiveTranscriptionService` wherever a test needs the event
/// contract without speech models or capture hardware — currently the
/// `RecordingCoordinator` tests.
///
/// The recorded state is lock-guarded rather than actor-isolated because the
/// real service is appended to from audio callback threads, and the assertions
/// that exercise that path have to read it from wherever the test happens to
/// be. Isolating it would either race inside the fake or force every caller
/// onto the main actor, hiding the concurrency the tests exist to exercise.
@MainActor
final class FakeLiveTranscriptionService: LiveTranscriptionServiceProtocol {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>
    private nonisolated let continuation: AsyncStream<LiveTranscriptionEvent>.Continuation

    private struct Recorded {
        var prepareCallCount = 0
        var prepareReturnCount = 0
        var prepareWasCancelled = false
        var preparedSources: [AudioSource] = []
        var preparedLocale: Locale?
        var appendedBuffers: [TaggedAudioBuffer] = []
        var appendThreadIDs: [UInt64] = []
        var didFinish = false
    }

    private nonisolated let recorded = OSAllocatedUnfairLock(uncheckedState: Recorded())

    /// Holds `prepare` open so a test can observe the coordinator while asset
    /// installation is still running. Armed before the coordinator creates the
    /// service; released by the test, or by cancelling the task that called
    /// `prepare`.
    private var prepareGate: AsyncStream<Void>?
    private var prepareGateContinuation: AsyncStream<Void>.Continuation?

    /// Called on the main actor when `prepare` returns, so a test can wait for
    /// the unwind instead of guessing how long cancellation takes.
    var onPrepareReturn: (() -> Void)?

    nonisolated init() {
        var escaped: AsyncStream<LiveTranscriptionEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    nonisolated var prepareCallCount: Int { recorded.withLockUnchecked { $0.prepareCallCount } }
    nonisolated var prepareReturnCount: Int { recorded.withLockUnchecked { $0.prepareReturnCount } }
    nonisolated var prepareWasCancelled: Bool { recorded.withLockUnchecked { $0.prepareWasCancelled } }
    nonisolated var preparedSources: [AudioSource] { recorded.withLockUnchecked { $0.preparedSources } }
    nonisolated var preparedLocale: Locale? { recorded.withLockUnchecked { $0.preparedLocale } }
    nonisolated var appendedBuffers: [TaggedAudioBuffer] {
        recorded.withLockUnchecked { $0.appendedBuffers }
    }
    nonisolated var appendThreadIDs: [UInt64] { recorded.withLockUnchecked { $0.appendThreadIDs } }
    nonisolated var didFinish: Bool { recorded.withLockUnchecked { $0.didFinish } }

    func blockPrepare() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        prepareGate = stream
        prepareGateContinuation = continuation
    }

    func releasePrepare() {
        prepareGateContinuation?.finish()
    }

    func prepare(sources: [AudioSource], locale: Locale) async {
        recorded.withLockUnchecked {
            $0.prepareCallCount += 1
            $0.preparedSources = sources
            $0.preparedLocale = locale
        }
        if let prepareGate {
            // Ends when the test releases the gate, or when the surrounding task
            // is cancelled — AsyncStream iteration returns on cancellation.
            for await _ in prepareGate {}
        }
        recorded.withLockUnchecked {
            $0.prepareReturnCount += 1
            $0.prepareWasCancelled = Task.isCancelled
        }
        onPrepareReturn?()
    }

    nonisolated func append(_ buffer: TaggedAudioBuffer) {
        let id = currentThreadID()
        recorded.withLockUnchecked {
            $0.appendedBuffers.append(buffer)
            $0.appendThreadIDs.append(id)
        }
    }

    /// Pushes an event as if a transcriber had produced it.
    nonisolated func emit(_ event: LiveTranscriptionEvent) {
        continuation.yield(event)
    }

    func finish() async {
        recorded.withLockUnchecked { $0.didFinish = true }
        continuation.finish()
    }
}

/// Hands the coordinator a fresh service per recording, the way the real
/// `LiveTranscriptionService` requires, and keeps every instance so a test can
/// assert across recordings.
@MainActor
final class FakeLiveTranscriptionFactory {
    private(set) var created: [FakeLiveTranscriptionService] = []

    /// Arms each new service's prepare gate, for tests that need `prepare` to
    /// still be running when they look at the coordinator.
    var armsPrepareGate = false

    /// Crashing here would abort the whole suite, so an empty list is reported
    /// as a stand-in service that fails whatever assertion follows.
    var latest: FakeLiveTranscriptionService {
        created.last ?? FakeLiveTranscriptionService()
    }

    func make() -> LiveTranscriptionServiceProtocol {
        let service = FakeLiveTranscriptionService()
        if armsPrepareGate { service.blockPrepare() }
        created.append(service)
        return service
    }
}
