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
        let buffer = makeToneBuffer(sampleCount: 16000)
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

        // With >= boundary: each 16000-frame buffer exactly meets samplesPerChunk (16000),
        // so each append triggers an emit. 2 buffers → 2 chunks.
        let expectation = expectation(description: "both chunks emitted")
        expectation.expectedFulfillmentCount = 2
        chunker.onChunk = { _, _ in
            chunkCount += 1
            expectation.fulfill()
        }

        // append 2 seconds worth of audio
        for i in 0..<2 {
            let buffer = makeToneBuffer(sampleCount: 16000)
            chunker.append(buffer, timestamp: Double(i))
        }

        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(chunkCount, 2)  // each 16000-frame buffer hits the >= boundary immediately
    }

    // Generates a 440 Hz sine wave well above the silence threshold (RMS ≈ 0.707)
    private func makeToneBuffer(sampleCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount)!
        buffer.frameLength = sampleCount
        let data = buffer.int16ChannelData![0]
        for i in 0..<Int(sampleCount) {
            data[i] = Int16(sin(2 * .pi * 440 * Double(i) / 16000) * 32767)
        }
        return buffer
    }

    // Zero-filled buffer — RMS == 0, should be silently dropped by AudioChunker
    private func makeSilenceBuffer(sampleCount: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: sampleCount)!
        buffer.frameLength = sampleCount
        return buffer
    }

    func test_silent_chunk_is_not_emitted() {
        let chunker = AudioChunker(chunkDuration: 30, outputDirectory: tempDir)
        var emitted = false
        chunker.onChunk = { _, _ in emitted = true }

        chunker.append(makeSilenceBuffer(sampleCount: 16000), timestamp: 0)
        chunker.flush()

        // flush() calls queue.sync — by the time it returns, _emitChunk has run
        XCTAssertFalse(emitted, "Silent chunks must not be emitted")
    }
}
