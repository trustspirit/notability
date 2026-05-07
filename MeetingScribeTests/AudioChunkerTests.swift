// MeetingScribeTests/AudioChunkerTests.swift
import XCTest
import AVFoundation
@testable import MeetingScribe

final class AudioChunkerTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func test_flush_writes_wav_file() throws {
        let chunker = AudioChunker(chunkDuration: 30, outputDirectory: tempDir)
        let buffer = makeSilenceBuffer(sampleCount: 16000)  // 1 second of silence
        chunker.append(buffer, timestamp: 0)

        let expectation = expectation(description: "chunk emitted")
        var emittedURL: URL?
        chunker.onChunk = { url, _ in
            emittedURL = url
            expectation.fulfill()
        }

        chunker.flush()
        wait(for: [expectation], timeout: 2)

        XCTAssertNotNil(emittedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: emittedURL!.path))
    }

    func test_auto_chunk_at_duration() throws {
        let chunker = AudioChunker(chunkDuration: 1, outputDirectory: tempDir)  // 1 second chunk for test
        var chunkCount = 0
        chunker.onChunk = { _, _ in chunkCount += 1 }

        // append 2 seconds worth of audio
        for i in 0..<2 {
            let buffer = makeSilenceBuffer(sampleCount: 16000)
            chunker.append(buffer, timestamp: Double(i))
        }

        XCTAssertEqual(chunkCount, 1)  // 1 chunk completed, 1 partial still buffered
    }

    private func makeSilenceBuffer(sampleCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount)!
        buffer.frameLength = sampleCount
        return buffer
    }
}
