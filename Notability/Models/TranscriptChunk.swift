import Foundation

struct TranscriptChunk: Codable, Equatable {
    let timestamp: TimeInterval  // seconds since meeting start
    let text: String
}

extension Array where Element == TranscriptChunk {
    /// Plain-text rendering suitable for clipboard / notes / email.
    /// One line per segment, prefixed with `[mm:ss]`.
    func formattedForCopy() -> String {
        map { chunk in
            let m = Int(chunk.timestamp) / 60
            let s = Int(chunk.timestamp) % 60
            return "[\(m):\(String(format: "%02d", s))] \(chunk.text)"
        }
        .joined(separator: "\n")
    }
}
