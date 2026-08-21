import AVFoundation

/// Derives buffer timestamps from accumulated frame counts rather than wall
/// clock time. SpeechAnalyzer rejects out-of-order timecodes with
/// `audioDisordered`, and wall-clock stamps drift from the true audio position
/// whenever the capture callback is delayed.
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

    var elapsed: TimeInterval {
        Double(framesElapsed) / sampleRate
    }
}
