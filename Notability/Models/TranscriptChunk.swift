import Foundation

struct TranscriptChunk: Codable, Equatable {
    let timestamp: TimeInterval  // seconds since meeting start
    let text: String
}
