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
    /// Seconds from recording start, derived from accumulated frame count.
    let startTime: TimeInterval
}
