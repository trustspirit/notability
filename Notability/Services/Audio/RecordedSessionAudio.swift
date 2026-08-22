import AVFoundation

/// Reports what a meeting's recorded audio can still be used for.
///
/// A file being on disk is not evidence that it can be decoded. Each source is
/// written to its own MPEG-4 file, and the container is only completed when
/// `SessionRecorder.finish()` releases the `AVAudioFile`. Until then the file
/// holds sample data behind a zeroed placeholder where the `moov` atom belongs,
/// and no decoder will open it — a process that dies before finishing leaves
/// exactly that.
///
/// The retention policy keeps audio until notes exist so any failure can be
/// retried, and that only makes sense for audio a retry could read. Telling the
/// two apart is what this is for.
///
/// Opening a file proves its container was completed. It does not prove every
/// sample behind it is intact; a read that fails partway through surfaces as an
/// ordinary mixing failure, which is retryable and reports its own reason.
enum RecordedSessionAudio {
    enum Inspection: Equatable {
        /// At least one track opens with audio in it. Carries every track a
        /// decoder can read, in `AudioSource.allCases` order.
        case usable(tracks: [URL])
        /// Track files are on disk but not one of them will open, which is what
        /// an unfinalised container looks like. No retry can change that.
        case unreadable
        /// Nothing was captured: no track files, or every one opens empty.
        case empty
    }

    static func trackURL(for source: AudioSource, in directory: URL) -> URL {
        directory.appendingPathComponent("\(source.fileBaseName).m4a")
    }

    static func inspect(directory: URL) -> Inspection {
        let tracks = AudioSource.allCases.map { trackURL(for: $0, in: directory) }
        let withAudio = tracks.filter { holdsAudio($0) }
        if !withAudio.isEmpty { return .usable(tracks: withAudio) }

        let present = tracks.filter { FileManager.default.fileExists(atPath: $0.path) }
        // A file that is there but will not open is the unfinalised case. One
        // that opens with no frames in it was closed properly and simply never
        // had anything written to it, which is not the same thing to say to the
        // user and not the same thing to do about it.
        if present.contains(where: { !canOpen($0) }) { return .unreadable }
        return .empty
    }

    /// True when the recording can still be transcribed.
    static func isUsable(directory: URL) -> Bool {
        if case .usable = inspect(directory: directory) { return true }
        return false
    }

    private static func holdsAudio(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0
    }

    private static func canOpen(_ url: URL) -> Bool {
        (try? AVAudioFile(forReading: url)) != nil
    }
}
