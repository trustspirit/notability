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
        var preparedSources: [AudioSource] = []
        var preparedLocale: Locale?
        var appendedBuffers: [TaggedAudioBuffer] = []
        var didFinish = false
    }

    private nonisolated let recorded = OSAllocatedUnfairLock(uncheckedState: Recorded())

    nonisolated init() {
        var escaped: AsyncStream<LiveTranscriptionEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    nonisolated var prepareCallCount: Int { recorded.withLockUnchecked { $0.prepareCallCount } }
    nonisolated var preparedSources: [AudioSource] { recorded.withLockUnchecked { $0.preparedSources } }
    nonisolated var preparedLocale: Locale? { recorded.withLockUnchecked { $0.preparedLocale } }
    nonisolated var appendedBuffers: [TaggedAudioBuffer] {
        recorded.withLockUnchecked { $0.appendedBuffers }
    }
    nonisolated var didFinish: Bool { recorded.withLockUnchecked { $0.didFinish } }

    func prepare(sources: [AudioSource], locale: Locale) async {
        recorded.withLockUnchecked {
            $0.prepareCallCount += 1
            $0.preparedSources = sources
            $0.preparedLocale = locale
        }
    }

    nonisolated func append(_ buffer: TaggedAudioBuffer) {
        recorded.withLockUnchecked { $0.appendedBuffers.append(buffer) }
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
