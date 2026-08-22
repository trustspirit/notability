import Foundation
import Combine
import os

/// Which system audio stream is owned, and whether system audio is reported as
/// running. One fact, so one lock.
///
/// ScreenCaptureKit hands a stream its delegate at construction, which means a
/// stream can be reported dead before `SCStream.startCapture()` has finished
/// returning. Three transitions therefore race: claiming a stream, reporting it
/// running, and reporting it dead. Each is applied against the identity of the
/// stream it concerns, so one whose stream has already been disowned does
/// nothing instead of reinstating state the disowning removed. Without that, a
/// stream dying during startup left the flag true and the recording claimed to
/// be capturing the far end while only the microphone was.
///
/// The availability send is enqueued from inside the lock too. Enqueuing after
/// releasing it would let two threads transition in one order and publish in
/// the other, leaving the getter and the publisher permanently disagreeing —
/// and the publisher is what the recording UI's banner follows.
///
/// Generic over the stream type because nothing here needs more than identity,
/// and an `SCStream` cannot be built without Screen Recording permission and a
/// display. That is what makes every ordering of these transitions testable.
final class SystemAudioOwnership<Stream: AnyObject>: @unchecked Sendable {
    private struct State {
        var stream: Stream?
        var isRunning = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private let availability = CurrentValueSubject<Bool, Never>(false)

    /// Replays the current value on subscription and emits on every change.
    /// Changes arrive on the main queue; the replayed value arrives on whichever
    /// thread subscribed.
    var availabilityPublisher: AnyPublisher<Bool, Never> {
        availability.eraseToAnyPublisher()
    }

    /// Up to date the moment a transition completes, without waiting for the
    /// main queue, so a caller reading it straight after `startCapture()`
    /// returns sees the truth.
    var isRunning: Bool {
        state.withLockUnchecked { $0.isRunning }
    }

    /// Takes ownership of a stream before it is started, so that a death
    /// arriving during the start has something to be recognised against.
    func claim(_ stream: Stream) {
        update { $0.stream = stream }
    }

    /// Reports system audio as running, unless `stream` has been disowned in the
    /// meantime — which is exactly what a stream that died while its
    /// `startCapture()` was returning looks like.
    func markRunning(_ stream: Stream) {
        update { state in
            guard state.stream === stream else { return }
            state.isRunning = true
        }
    }

    /// Disowns `stream` and reports system audio as stopped. A stream that is
    /// not the owned one is ignored, so a previous recording's stream reporting
    /// itself dead cannot take down the current one.
    func release(_ stream: Stream) {
        update { state in
            guard state.stream === stream else { return }
            state.stream = nil
            state.isRunning = false
        }
    }

    /// Disowns whatever is held, for a caller with no particular stream in hand.
    func releaseAny() {
        update { state in
            state.stream = nil
            state.isRunning = false
        }
    }

    /// Hands back the owned stream so the caller can shut it down, reporting
    /// system audio as stopped in the same breath.
    func take() -> Stream? {
        var taken: Stream?
        update { state in
            taken = state.stream
            state.stream = nil
            state.isRunning = false
        }
        return taken
    }

    private func update(_ change: (inout State) -> Void) {
        state.withLockUnchecked { state in
            let before = state.isRunning
            change(&state)
            guard state.isRunning != before else { return }
            let value = state.isRunning
            // Hopped because the only subscriber is UI, and enqueued here rather
            // than after the unlock so that the order subscribers see is the
            // order the transitions happened in.
            DispatchQueue.main.async { [self] in
                availability.send(value)
            }
        }
    }
}
