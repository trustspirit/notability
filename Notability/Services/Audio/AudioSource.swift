import AVFoundation

enum AudioSource: String, Codable, CaseIterable {
    case microphone
    case systemAudio

    /// Label shown in the live transcript before diarization assigns real names.
    var defaultSpeakerLabel: String {
        switch self {
        case .microphone: return "나"
        case .systemAudio: return "상대방"
        }
    }

    var fileBaseName: String {
        switch self {
        case .microphone: return "mic"
        case .systemAudio: return "system"
        }
    }
}

/// Which sources a recording captures.
///
/// Not the same question as which sources a recording *ended up* with. A
/// meeting can lose system audio because Screen Recording was never granted,
/// and that is a problem to report; choosing `.microphoneOnly` is the user
/// saying there is nothing to report. Everything downstream already treats a
/// missing system track as normal, so this only decides what capture attempts
/// — and what the UI is allowed to complain about.
enum RecordingMode: String, Codable, CaseIterable {
    case microphoneAndSystem
    case microphoneOnly

    var capturesSystemAudio: Bool { self == .microphoneAndSystem }
}

struct TaggedAudioBuffer {
    let source: AudioSource
    let buffer: AVAudioPCMBuffer
    /// Seconds from the start of the recording, on the one timeline both
    /// sources are stamped against; see `AudioCaptureServiceProtocol
    /// .bufferPublisher` for what that does and does not promise.
    let startTime: TimeInterval
}
