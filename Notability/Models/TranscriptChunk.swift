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

extension TranscriptChunk {
    /// The speaker to attribute this segment to, or nil when there is nothing
    /// worth attributing: legacy transcripts carry no speaker at all, and the
    /// diarization API can return an empty or blank one. Display and clipboard
    /// output both go through here so a segment never renders an empty label in
    /// one place and a bare `:` in the other.
    var displaySpeaker: String? {
        guard let trimmed = speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// A transcript chunk paired with an identity that is safe to use as a `ForEach`
/// id. See `identifiedRows()` for why the chunk cannot supply one itself.
struct IdentifiedTranscriptChunk: Identifiable, Equatable {
    let id: Int
    let chunk: TranscriptChunk
}

extension Array where Element == TranscriptChunk {
    /// Pairs each chunk with its position, which is the only identity guaranteed
    /// to be unique. Timestamps are not: the diarized transcript is the API's
    /// segment list verbatim, and overlapping speech or a chunk boundary can
    /// yield two segments sharing a start time. Duplicate `ForEach` ids make
    /// SwiftUI drop or misplace rows.
    ///
    /// Positional identity re-renders rows rather than moving them when the list
    /// shifts. A stored transcript never shifts. Live captions do: the provisional
    /// row for one source moves down when the other source finalizes a row ahead
    /// of it. That only touches the last row or two, whose text is changing on
    /// every event anyway, so the re-render costs nothing worth a stable segment
    /// id — but a feature that reorders or inserts earlier rows would need one.
    func identifiedRows() -> [IdentifiedTranscriptChunk] {
        enumerated().map { IdentifiedTranscriptChunk(id: $0.offset, chunk: $0.element) }
    }

    /// Plain-text rendering suitable for clipboard / notes / email.
    /// One line per segment, prefixed with `[mm:ss]` and the speaker when known.
    func formattedForCopy() -> String {
        map { chunk in
            let m = Int(chunk.timestamp) / 60
            let s = Int(chunk.timestamp) % 60
            let time = "[\(m):\(String(format: "%02d", s))]"
            guard let speaker = chunk.displaySpeaker else {
                return "\(time) \(chunk.text)"
            }
            return "\(time) \(speaker): \(chunk.text)"
        }
        .joined(separator: "\n")
    }
}
