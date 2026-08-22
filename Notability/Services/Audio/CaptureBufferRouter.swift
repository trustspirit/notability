import AVFoundation

/// Hands one captured buffer to the two consumers that need it, on the thread
/// that captured it.
///
/// This exists as a separate type rather than a closure inside
/// `RecordingCoordinator` so that the coordinator's main-actor state is not
/// reachable from the audio path at all. The contract that the fan-out performs
/// no main-actor work is then enforced by what this type can see, instead of by
/// a reviewer noticing a stray property access.
///
/// Everything it holds is established before the buffer subscription is taken
/// and never mutated, and a router is built fresh per recording. So there is no
/// state here for a capture thread and the main actor to race over, and `route`
/// takes no lock of its own.
///
/// `route` runs inside `CaptureBufferRelay`'s critical section, which is why it
/// must neither block nor call back into the capture service — see
/// `AudioCaptureServiceProtocol.bufferPublisher`. Both calls it makes are
/// non-blocking handoffs: the recorder enqueues onto its own serial queue, and
/// live transcription yields into an `AsyncStream`.
final class CaptureBufferRouter: @unchecked Sendable {
    private let recorders: [AudioSource: SessionAudioWriting]
    private let liveTranscription: LiveTranscriptionServiceProtocol

    init(
        recorders: [AudioSource: SessionAudioWriting],
        liveTranscription: LiveTranscriptionServiceProtocol
    ) {
        self.recorders = recorders
        self.liveTranscription = liveTranscription
    }

    /// Call synchronously from the capture callback that produced `tagged`, one
    /// thread per source. Wrapping this in a task would lose the per-source
    /// ordering that live captions depend on.
    func route(_ tagged: TaggedAudioBuffer) {
        // The recorder first: it feeds the transcript the user is actually
        // billed for, so it should not queue behind the display-only tier.
        recorders[tagged.source]?.append(tagged.buffer, startTime: tagged.startTime)
        liveTranscription.append(tagged)
    }
}
