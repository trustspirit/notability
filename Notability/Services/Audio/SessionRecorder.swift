import AVFoundation

/// Continuously records one capture source to an AAC file for the duration of a
/// meeting. Roughly 11 MB per hour at 24 kbps, which keeps a two-hour meeting
/// under the transcription API's 25 MB upload limit.
final class SessionRecorder {
    let url: URL

    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.notability.sessionrecorder", qos: .utility)

    init(directory: URL, source: AudioSource, sampleRate: Double) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(source.fileBaseName).m4a")
        try? FileManager.default.removeItem(at: url)
        // commonFormat/interleaved declare the *processing* format the caller writes in
        // (Int16, matching the 16 kHz mono capture format); the file itself still
        // encodes to AAC per `settings`. Without this, AVAudioFile defaults its
        // processing format to Float32 and `append` throws on the Int16 buffers
        // the capture layer hands us.
        file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 24_000
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        queue.async { [weak self] in
            guard let file = self?.file else { return }
            do {
                try file.write(from: buffer)
            } catch {
                print("[SessionRecorder] write failed: \(error)")
            }
        }
    }

    /// Flushes pending writes and closes the file. Appends after this are dropped.
    func finish() {
        queue.sync {
            // Releasing the AVAudioFile is what finalises the container.
            file = nil
        }
    }
}
