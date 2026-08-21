import Foundation
import os
@testable import Notability

/// Stands in for `LiveTranscriptionService` wherever a test needs the event
/// contract without speech models or capture hardware — currently the
/// `RecordingCoordinator` tests.
///
/// The recorded state is lock-guarded because the real service is appended to
/// from audio callback threads, and tests that exercise that path would
/// otherwise race inside the fake rather than in the code under test.
final class FakeLiveTranscriptionService: LiveTranscriptionServiceProtocol, @unchecked Sendable {
    let events: AsyncStream<LiveTranscriptionEvent>
    private let continuation: AsyncStream<LiveTranscriptionEvent>.Continuation

    private struct Recorded {
        var prepareCallCount = 0
        var preparedSources: [AudioSource] = []
        var preparedLocale: Locale?
        var appendedBuffers: [TaggedAudioBuffer] = []
        var didFinish = false
    }

    private let recorded = OSAllocatedUnfairLock(uncheckedState: Recorded())

    init() {
        var escaped: AsyncStream<LiveTranscriptionEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    var prepareCallCount: Int { recorded.withLockUnchecked { $0.prepareCallCount } }
    var preparedSources: [AudioSource] { recorded.withLockUnchecked { $0.preparedSources } }
    var preparedLocale: Locale? { recorded.withLockUnchecked { $0.preparedLocale } }
    var appendedBuffers: [TaggedAudioBuffer] { recorded.withLockUnchecked { $0.appendedBuffers } }
    var didFinish: Bool { recorded.withLockUnchecked { $0.didFinish } }

    func prepare(sources: [AudioSource], locale: Locale) async {
        recorded.withLockUnchecked {
            $0.prepareCallCount += 1
            $0.preparedSources = sources
            $0.preparedLocale = locale
        }
    }

    func append(_ buffer: TaggedAudioBuffer) {
        recorded.withLockUnchecked { $0.appendedBuffers.append(buffer) }
    }

    /// Pushes an event as if a transcriber had produced it.
    func emit(_ event: LiveTranscriptionEvent) {
        continuation.yield(event)
    }

    func finish() async {
        recorded.withLockUnchecked { $0.didFinish = true }
        continuation.finish()
    }
}
