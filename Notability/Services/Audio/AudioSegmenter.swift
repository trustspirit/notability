import AVFoundation

enum AudioSegmenterError: Error, LocalizedError {
    case exportUnavailable

    var errorDescription: String? {
        "Could not split the recording into uploadable segments."
    }
}

/// Cuts a recording into pieces the transcription API will accept.
///
/// `gpt-4o-transcribe-diarize` refuses any request carrying more than 1400
/// seconds of audio, and `chunking_strategy` does not raise that ceiling — it
/// only tells the server how to cut within it. So a meeting longer than about
/// 23 minutes has to arrive as several requests, which is what this produces.
enum AudioSegmenter {
    private static let chunkFrameCount: AVAudioFrameCount = 16_384

    struct Segment: Equatable {
        let url: URL
        /// Where this segment begins on the original recording's timeline, so
        /// the timestamps that come back can be put back where they belong.
        let startTime: TimeInterval
    }

    struct Config {
        /// The longest recording that still goes up as a single request. Set
        /// below the API's 1400 s so a rounding error cannot land on it.
        var requestLimit: TimeInterval = 1_380
        /// Divides the recording into as few segments as the limit allows.
        /// Segments are then sized evenly rather than filled to this, so no
        /// segment is left with a fraction of the context the others get.
        var targetDuration: TimeInterval = 1_200
        /// How far either side of an even boundary to look for a pause.
        var searchWindow: TimeInterval = 60
        /// A gap shorter than this is a breath between words, not a break
        /// between sentences, and cutting there splits the sentence anyway.
        var minimumSilence: TimeInterval = 0.5
        var analysisWindow: TimeInterval = 0.02
        var silenceRMSThreshold: Float = 0.002

        init() {}
    }

    static func split(
        _ sourceURL: URL,
        into directory: URL,
        config: Config = Config()
    ) async throws -> [Segment] {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration > config.requestLimit else {
            return [Segment(url: sourceURL, startTime: 0)]
        }

        let count = Int(ceil(duration / config.targetDuration))
        let spacing = duration / Double(count)
        let file = try AVAudioFile(forReading: sourceURL)

        // Cuts are placed in order, each one bounded by what the cuts around it
        // still need. Moving a boundary to a pause is only ever an adjustment
        // within those bounds, so no run of adjustments can produce a segment
        // the API would reject.
        var cuts: [TimeInterval] = []
        var previous: TimeInterval = 0
        for index in 1..<count {
            let target = Double(index) * spacing
            // Far enough along that the segments still to come can cover the
            // rest, and near enough that the segment just closed fits in one
            // request.
            let earliest = max(previous, duration - Double(count - index) * config.requestLimit)
            let latest = min(duration, previous + config.requestLimit)
            // No pause anywhere near the boundary means someone is talking
            // straight through it. Cutting mid-sentence is the lesser evil
            // against exceeding the request limit.
            let cut = try pause(near: target, in: file, within: earliest...latest, config: config)
                ?? min(max(target, earliest), latest)
            cuts.append(cut)
            previous = cut
        }
        cuts.append(duration)

        var segments: [Segment] = []
        var cutStart: TimeInterval = 0
        var timelinePosition: TimeInterval = 0
        for (index, cutEnd) in cuts.enumerated() {
            let url = directory.appendingPathComponent("segment-\(index).m4a")
            try await export(asset: asset, from: cutStart, to: cutEnd, to: url)
            segments.append(Segment(url: url, startTime: timelinePosition))
            // Passthrough cuts land on AAC frame boundaries, so a segment is
            // not exactly as long as it was asked to be. Advancing by what was
            // actually written keeps the segments' timeline equal to the
            // recording they were cut from.
            timelinePosition += try await AVURLAsset(url: url).load(.duration).seconds
            cutStart = cutEnd
        }
        return segments
    }

    /// The middle of the pause nearest the target, or `nil` when the window
    /// holds none long enough to be a break between sentences.
    ///
    /// Nearest rather than longest: any pause that clears the threshold is a
    /// sentence break, and a longer one further away is not a better place to
    /// cut — it only drags the boundary off the even size the split chose,
    /// which is the whole reason the sizes were evened out.
    ///
    /// The middle of the pause rather than either edge, so both the segment
    /// that ends here and the one that starts here keep some of the silence; a
    /// cut flush against speech clips the first or last syllable.
    ///
    /// Only the window is read, by seeking to it. A two-hour recording is never
    /// scanned end to end.
    private static func pause(
        near target: TimeInterval,
        in file: AVAudioFile,
        within bounds: ClosedRange<TimeInterval>,
        config: Config
    ) throws -> TimeInterval? {
        let sampleRate = file.processingFormat.sampleRate
        let windowStart = max(bounds.lowerBound, target - config.searchWindow)
        let windowEnd = min(bounds.upperBound, target + config.searchWindow)
        guard windowEnd > windowStart else { return nil }

        let blockFrames = max(1, Int(config.analysisWindow * sampleRate))
        let blockDuration = Double(blockFrames) / sampleRate
        file.framePosition = AVAudioFramePosition(windowStart * sampleRate)
        guard let reader = BlockRMSReader(
            file: file,
            blockFrames: blockFrames,
            chunkFrameCount: chunkFrameCount
        ) else {
            return nil
        }

        var nearest: TimeInterval?
        var runStart: Int?

        func consider(_ run: Range<Int>) {
            guard Double(run.count) * blockDuration >= config.minimumSilence else { return }
            let centre = windowStart + (Double(run.lowerBound) + Double(run.count) / 2) * blockDuration
            guard let best = nearest else {
                nearest = centre
                return
            }
            if abs(centre - target) < abs(best - target) { nearest = centre }
        }

        var index = 0
        let blockCount = Int((windowEnd - windowStart) / blockDuration)
        while index < blockCount, let rms = try reader.nextBlockRMS() {
            if rms < config.silenceRMSThreshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                consider(start..<index)
                runStart = nil
            }
            index += 1
        }
        if let start = runStart { consider(start..<index) }

        return nearest
    }

    /// Copies a time range out of the source without re-encoding it. The
    /// recording is already 24 kbps AAC; decoding and re-encoding it would cost
    /// a second generation of loss on exactly the audio being transcribed.
    private static func export(
        asset: AVAsset,
        from start: TimeInterval,
        to end: TimeInterval,
        to url: URL
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw AudioSegmenterError.exportUnavailable
        }
        session.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
        try await session.export(to: url, as: .m4a)
    }
}
