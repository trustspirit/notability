import Foundation

/// Turns the live transcription event stream into the two things the recording
/// view shows: caption rows and a one-line notice.
///
/// A value type with no isolation and no I/O, so the rules it encodes — which
/// row a result replaces, which notice outranks which — are testable directly
/// rather than through a recording session.
struct LiveCaptionAggregator {
    private var finalizedRows: [TranscriptChunk] = []
    private var volatileRows: [AudioSource: TranscriptChunk] = [:]
    private var downloadNotice: String?
    private var unavailableNotice: String?

    /// Confirmed rows in the order they were confirmed, then at most one
    /// provisional row per source.
    ///
    /// Neither group is sorted by timestamp. The two sources' timestamps are
    /// comparable, but sorting by them makes a row the user has already read jump
    /// down the list whenever the other source confirms an earlier segment, and
    /// provisional rows would jump on every partial result. Chronological
    /// ordering is the diarized pass's job; this tier only has to be readable.
    var visibleRows: [TranscriptChunk] {
        finalizedRows + AudioSource.allCases.compactMap { volatileRows[$0] }
    }

    /// A hard failure outranks download progress: the download will finish on its
    /// own, whereas "captions are not running" is the state the user needs to see.
    var notice: String? {
        unavailableNotice ?? downloadNotice
    }

    /// Applies one event and reports which of the two published values moved, so
    /// the caller can skip republishing to SwiftUI. Volatile results arrive
    /// several times a second per source and are frequently the same string.
    @discardableResult
    mutating func apply(_ event: LiveTranscriptionEvent) -> (rowsChanged: Bool, noticeChanged: Bool) {
        let rowsBefore = visibleRows
        let noticeBefore = notice

        switch event {
        case .downloading(let progress):
            let percent = Int((progress * 100).rounded())
            downloadNotice = "Downloading the on-device speech model… \(percent)%"
        case .ready:
            downloadNotice = nil
        case .volatile(let source, let text, let startTime):
            volatileRows[source] = row(text: text, startTime: startTime, source: source)
        case .finalized(let source, let text, let startTime):
            volatileRows[source] = nil
            finalizedRows.append(row(text: text, startTime: startTime, source: source))
        case .unavailable(let message):
            unavailableNotice = message
        }

        return (rowsChanged: visibleRows != rowsBefore, noticeChanged: notice != noticeBefore)
    }

    private func row(text: String, startTime: TimeInterval, source: AudioSource) -> TranscriptChunk {
        TranscriptChunk(timestamp: startTime, text: text, speaker: source.defaultSpeakerLabel)
    }
}
