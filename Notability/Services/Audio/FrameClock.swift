import AVFoundation

/// Derives buffer timestamps from accumulated frame counts rather than wall
/// clock time. SpeechAnalyzer rejects out-of-order timecodes with
/// `audioDisordered`, and wall-clock stamps drift from the true audio position
/// whenever the capture callback is delayed.
///
/// Counting frames alone cannot tell where a source's audio *begins*, nor that
/// a source stopped delivering for a while: both look like time that never
/// passed. `skip(toFrame:)` is how the owner supplies that information from a
/// clock that does know, without giving up frame-derived spacing in between.
struct FrameClock {
    let sampleRate: Double
    private(set) var framesElapsed: AVAudioFramePosition = 0

    init(sampleRate: Double) {
        precondition(sampleRate > 0, "sampleRate must be positive, got \(sampleRate)")
        self.sampleRate = sampleRate
    }

    /// Returns the start time of the buffer being appended, then advances past it.
    ///
    /// Callers must not pass zero frame counts: `advance(by: 0)` repeats the same
    /// timestamp and breaks strict monotonicity. Empty buffers are filtered before
    /// stamping because SpeechAnalyzer requires strictly increasing timecodes.
    mutating func advance(by frameCount: AVAudioFrameCount) -> TimeInterval {
        let start = Double(framesElapsed) / sampleRate
        framesElapsed += AVAudioFramePosition(frameCount)
        return start
    }

    /// Jumps the clock forward to `frame`, leaving a hole in the timeline for
    /// audio that was never delivered.
    ///
    /// Never moves backwards. A clock that went back would hand out a timestamp
    /// it had already used, which is exactly the disordered audio SpeechAnalyzer
    /// refuses, so a `frame` that is behind where the delivered frames have
    /// already reached is ignored rather than honoured.
    mutating func skip(toFrame frame: AVAudioFramePosition) {
        framesElapsed = max(framesElapsed, frame)
    }

    var elapsed: TimeInterval {
        Double(framesElapsed) / sampleRate
    }
}
