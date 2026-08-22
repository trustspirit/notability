import XCTest
import Combine

extension XCTestCase {
    /// Waits until `publisher` emits a value satisfying `predicate`.
    ///
    /// Prefer this over sleeping for a guessed propagation delay: the wait ends
    /// on the value it is waiting for, so it costs nothing on a fast machine and
    /// does not fail on a loaded one. `timeout` is only ever reached when the
    /// behaviour under test is broken.
    ///
    /// `@Published` projections replay their current value on subscription, so a
    /// condition that already holds satisfies this immediately.
    @MainActor
    func waitUntil<P: Publisher>(
        _ publisher: P,
        satisfies predicate: @escaping (P.Output) -> Bool,
        description: String,
        timeout: TimeInterval = 5
    ) async where P.Failure == Never {
        let matched = expectation(description: description)
        var hasMatched = false
        let cancellable = publisher.sink { value in
            guard !hasMatched, predicate(value) else { return }
            hasMatched = true
            matched.fulfill()
        }
        await fulfillment(of: [matched], timeout: timeout)
        cancellable.cancel()
    }

    /// Returns once every block already enqueued on the main queue has run.
    ///
    /// For negative assertions, where there is no value to wait for. The main
    /// queue is FIFO, so anything dispatched before this call has completed by
    /// the time it returns — which is what makes "and then nothing happened" a
    /// deterministic claim rather than a race.
    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// Runs `body` to completion on a dedicated thread that is not the main queue
/// and not a cooperative-pool worker, and returns that thread's id.
///
/// The capture layer delivers buffers from an audio engine tap thread and from
/// ScreenCaptureKit's sample queue. A test that emits from the main queue cannot
/// tell a correct fan-out from one that hops threads, because on the main queue
/// both look the same.
@discardableResult
func onDedicatedThread(_ body: @escaping () -> Void) -> UInt64 {
    let finished = DispatchSemaphore(value: 0)
    var threadID: UInt64 = 0
    let thread = Thread {
        threadID = currentThreadID()
        body()
        finished.signal()
    }
    thread.start()
    finished.wait()
    return threadID
}

func currentThreadID() -> UInt64 {
    var id: UInt64 = 0
    pthread_threadid_np(nil, &id)
    return id
}
