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

struct TaggedAudioBuffer {
    let source: AudioSource
    let buffer: AVAudioPCMBuffer
    /// Seconds from the start of the recording, on the one timeline both
    /// sources are stamped against; see `AudioCaptureServiceProtocol
    /// .bufferPublisher` for what that does and does not promise.
    let startTime: TimeInterval
}
