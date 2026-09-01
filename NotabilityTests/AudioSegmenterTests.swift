import AVFoundation
import XCTest
@testable import Notability

final class AudioSegmenterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioSegmenterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRecordingWithinTheRequestLimitIsSentWhole() async throws {
        let source = directory.appendingPathComponent("mixed.m4a")
        try AudioFixtures.writeTrack(AudioFixtures.tone(seconds: 3), to: source)

        let segments = try await AudioSegmenter.split(source, into: directory, config: testConfig())

        XCTAssertEqual(segments, [AudioSegmenter.Segment(url: source, startTime: 0)])
    }

    func testRecordingOverTheLimitIsSplitIntoEvenlySizedSegments() async throws {
        // 15s against a 6s target splits into 3 rather than 6+6+3, so no
        // segment is left with a fraction of the context the others get.
        let source = directory.appendingPathComponent("mixed.m4a")
        try AudioFixtures.writeTrack(AudioFixtures.tone(seconds: 15), to: source)

        let segments = try await AudioSegmenter.split(source, into: directory, config: testConfig())

        XCTAssertEqual(segments.count, 3)
        for segment in segments {
            let seconds = try await duration(of: segment.url)
            XCTAssertEqual(seconds, 5, accuracy: 0.3)
        }
    }

    func testBoundaryMovesToThePauseNearestTheTarget() async throws {
        // Even boundaries would cut at 5s, mid-word. A one-second pause sits at
        // 3...4, inside the search window, so the cut belongs at its centre.
        let source = directory.appendingPathComponent("mixed.m4a")
        try AudioFixtures.writeTrack(speech(seconds: 15, pauses: [3...4]), to: source)

        let segments = try await AudioSegmenter.split(
            source,
            into: directory,
            config: testConfig(searchWindow: 2)
        )

        let first = try await duration(of: segments[0].url)
        XCTAssertEqual(first, 3.5, accuracy: 0.3)
    }

    /// A tone with silent stretches cut out of it, standing in for a recording
    /// where someone stops talking.
    private func speech(seconds: Double, pauses: [ClosedRange<Double>]) -> AVAudioPCMBuffer {
        AudioFixtures.buffer(seconds: seconds) { index in
            let time = Double(index) / 16_000
            guard !pauses.contains(where: { $0.contains(time) }) else { return 0 }
            return 0.5 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }
    }

    func testTheQualifyingPauseNearestTheTargetWins() async throws {
        // Real speech pauses at every sentence, so the window usually holds
        // several candidates. Any pause long enough to clear the threshold is
        // a sentence break; a longer one further away is not a better place to
        // cut, it just drags the boundary off the even size the split chose.
        // Here the further pause is the longer one, and should still lose.
        let source = directory.appendingPathComponent("mixed.m4a")
        try AudioFixtures.writeTrack(speech(seconds: 15, pauses: [2.2...3.0, 4.4...5.0]), to: source)

        let segments = try await AudioSegmenter.split(
            source,
            into: directory,
            config: testConfig(searchWindow: 3)
        )

        let first = try await duration(of: segments[0].url)
        XCTAssertEqual(first, 4.7, accuracy: 0.2)
    }

    func testNoSegmentExceedsTheRequestLimitWhenPausesPushBoundariesApart() async throws {
        // The pause before boundary 1 pulls it back to 3.5; the pause after
        // boundary 2 pushes it out to 12. Left alone that leaves 8.5 seconds
        // between them, which the API would reject.
        let source = directory.appendingPathComponent("mixed.m4a")
        try AudioFixtures.writeTrack(speech(seconds: 15, pauses: [2.5...3.5, 11.5...12.5]), to: source)

        let segments = try await AudioSegmenter.split(
            source,
            into: directory,
            config: testConfig(searchWindow: 3)
        )

        for segment in segments {
            let seconds = try await duration(of: segment.url)
            XCTAssertLessThanOrEqual(seconds, 8, "segment at \(segment.startTime)s is over the request limit")
        }
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// Scaled down from the real 1380/1200/60 seconds so a fixture stays small
    /// enough to encode in a test. The ratios are what the logic depends on.
    private func testConfig(
        requestLimit: TimeInterval = 8,
        targetDuration: TimeInterval = 6,
        searchWindow: TimeInterval = 1
    ) -> AudioSegmenter.Config {
        var config = AudioSegmenter.Config()
        config.requestLimit = requestLimit
        config.targetDuration = targetDuration
        config.searchWindow = searchWindow
        return config
    }
}
