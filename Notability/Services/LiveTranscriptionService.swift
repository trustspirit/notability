import AVFoundation
import Speech

/// On-device live captions via `SpeechAnalyzer`. One analyzer per capture
/// source; both use the same locale and options so they share backing engines.
///
/// This tier is display-only. The authoritative transcript comes from the
/// diarized pass after recording stops, so a caption stall or a missing model
/// never degrades the meeting notes — every failure here is reported and
/// swallowed rather than propagated.
///
/// Isolated to the main actor because the protocol's "one serialized context"
/// requirement has to be enforced somewhere. An `async` method on a plain class
/// runs on the cooperative pool and does not inherit its caller's actor, so a
/// `finish()` launched while a slow `prepare` is still downloading assets would
/// otherwise mutate the same dictionaries from a second thread. `append` opts
/// back out: it comes from realtime audio threads and reaches only `registry`,
/// which carries its own lock.
@MainActor
final class LiveTranscriptionService: LiveTranscriptionServiceProtocol {
    nonisolated let events: AsyncStream<LiveTranscriptionEvent>
    private nonisolated let continuation: AsyncStream<LiveTranscriptionEvent>.Continuation

    /// The only state `append` reaches, and the only state that needs a lock.
    private nonisolated let registry = AnalyzerInputRegistry()

    // Main-actor state. The serial executor is what makes the `didFinish`
    // guards below sufficient rather than hopeful: a concurrent `finish()` can
    // only overtake an in-flight `prepare` at one of `prepare`'s own awaits,
    // never part-way through one of these mutations.
    private var analyzers: [AudioSource: SpeechAnalyzer] = [:]
    private var readers: [AudioSource: Task<Void, Never>] = [:]
    private var didFinish = false

    /// Nonisolated so a caller on any context can own the instance before it
    /// has an actor to hop to; nothing here touches isolated state.
    nonisolated init() {
        var escaped: AsyncStream<LiveTranscriptionEvent>.Continuation!
        // Captions are worth bounding: volatile results arrive several times a
        // second per source, and an unbounded stream behind a slow consumer
        // grows for the whole meeting. Overflowing 512 needs a main-actor stall
        // of minutes; if it happened, the dropped element is the next line the
        // user would have seen, and a dropped `.finalized` loses that row for
        // good. It never costs transcript text — that comes from the recording.
        events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { escaped = $0 }
        continuation = escaped
    }

    /// The locale a transcriber can actually run, which may differ in region
    /// from the one asked for. Reflects framework support, not whether the model
    /// has been downloaded — installation is `prepare`'s job.
    nonisolated static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    nonisolated static func isSupported(locale: Locale) async -> Bool {
        await supportedLocale(equivalentTo: locale) != nil
    }

    func prepare(sources: [AudioSource], locale: Locale) async {
        guard !didFinish else { return }
        guard let supported = await Self.supportedLocale(equivalentTo: locale) else {
            continuation.yield(.unavailable(
                "On-device transcription does not support \(locale.identifier). "
                    + "Live captions are off; the final transcript is unaffected."
            ))
            return
        }

        for source in sources {
            guard !didFinish else { break }
            do {
                try await startAnalyzer(for: source, locale: supported)
            } catch {
                // Resource limits are per-machine and undocumented. Dropping one
                // source keeps captions running for the other rather than losing both.
                continuation.yield(.unavailable(
                    "Live captions unavailable for \(source.rawValue): \(error.localizedDescription)"
                ))
            }
        }

        if !registry.isEmpty {
            continuation.yield(.ready)
        }
    }

    private func startAnalyzer(for source: AudioSource, locale: Locale) async throws {
        // Presets bundling .fastResults trade accuracy for latency; meeting
        // captions are read, not acted on in milliseconds, so accuracy wins.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        try await installAssets(for: transcriber)
        // A 300 MB download can outlast the recording that asked for it, so bail
        // out before paying for an analyzer nobody will use.
        guard !didFinish else { return }

        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        // Started before the analyzer so no early result can be missed, which
        // leaves a failed handshake to tear it back down.
        let reader = resultReader(for: source, of: transcriber)
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            inputContinuation.finish()
            // The analyzer never ran, so there is nothing to finalize and no
            // result will ever arrive. Cancellation is the only handle left;
            // whether `transcriber.results` observes it is undocumented, so
            // this may leave one parked task per failed source rather than
            // reclaiming it.
            reader.cancel()
            throw error
        }

        // finish() may still have landed during either await above. Publishing
        // now would hand it an analyzer it has already stopped looking for.
        guard !didFinish else {
            await Self.shutDown(analyzer, input: inputContinuation, reader: reader)
            return
        }

        readers[source] = reader
        analyzers[source] = analyzer
        registry.register(
            AnalyzerInputSink(targetFormat: format, continuation: inputContinuation),
            for: source
        )
    }

    private static func shutDown(
        _ analyzer: SpeechAnalyzer,
        input: AsyncStream<AnalyzerInput>.Continuation,
        reader: Task<Void, Never>
    ) async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        await reader.value
    }

    private func installAssets(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }

        let progress = request.progress
        let reporter = Task { [continuation] in
            while !Task.isCancelled && !progress.isFinished {
                continuation.yield(.downloading(progress: progress.fractionCompleted))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }

    /// Nonisolated so the task it spawns does not inherit the main actor. This
    /// loop lives as long as the recording and wakes on every volatile result,
    /// several times a second per source; scheduling that on the actor that
    /// drives the UI buys nothing, since the only state it touches is the
    /// continuation, which is thread-safe.
    private nonisolated func resultReader(
        for source: AudioSource,
        of transcriber: SpeechTranscriber
    ) -> Task<Void, Never> {
        Task { [continuation] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    let start = result.range.start.seconds
                    // Volatile results replace the previous provisional text for
                    // this source; they are never accumulated.
                    continuation.yield(
                        result.isFinal
                            ? .finalized(source: source, text: text, startTime: start)
                            : .volatile(source: source, text: text, startTime: start)
                    )
                }
            } catch {
                continuation.yield(.unavailable(
                    "Live captions stopped for \(source.rawValue): \(error.localizedDescription)"
                ))
            }
        }
    }

    nonisolated func append(_ buffer: TaggedAudioBuffer) {
        registry.sink(for: buffer.source)?.send(buffer)
    }

    func finish() async {
        didFinish = true
        // Unregister before finishing: an audio callback already inside send()
        // then yields into a closed continuation, which is a documented no-op.
        for sink in registry.removeAll() { sink.finish() }

        for analyzer in analyzers.values {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        for reader in readers.values { await reader.value }

        analyzers.removeAll()
        readers.removeAll()
        continuation.finish()
    }
}
