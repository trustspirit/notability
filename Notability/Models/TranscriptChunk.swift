import Foundation

struct TranscriptChunk: Codable, Equatable {
    let timestamp: TimeInterval  // seconds since meeting start
    let text: String
    // nil for transcripts recorded before speaker attribution existed.
    let speaker: String?

    init(timestamp: TimeInterval, text: String, speaker: String? = nil) {
        self.timestamp = timestamp
        self.text = text
        self.speaker = speaker
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(TimeInterval.self, forKey: .timestamp)
        text = try container.decode(String.self, forKey: .text)
        speaker = try container.decodeIfPresent(String.self, forKey: .speaker)
    }
}

extension Array where Element == TranscriptChunk {
    /// Plain-text rendering suitable for clipboard / notes / email.
    /// One line per segment, prefixed with `[mm:ss]` and the speaker when known.
    func formattedForCopy() -> String {
        map { chunk in
            let m = Int(chunk.timestamp) / 60
            let s = Int(chunk.timestamp) % 60
            let time = "[\(m):\(String(format: "%02d", s))]"
            guard let speaker = chunk.speaker, !speaker.isEmpty else {
                return "\(time) \(chunk.text)"
            }
            return "\(time) \(speaker): \(chunk.text)"
        }
        .joined(separator: "\n")
    }
}
