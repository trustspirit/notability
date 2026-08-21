import XCTest
import AVFoundation
import Speech
@testable import Notability

/// The happy path needs downloaded speech models and live capture hardware, so
/// what is verified here is the event contract, the availability decision, and
/// that a failed `prepare` leaves nothing behind for the audio thread to hit.
final class LiveTranscriptionServiceTests: XCTestCase {
    /// Consumes the stream to completion inside a single task, so the collected
    /// events are only ever touched by one context and are read after the stream
    /// has actually ended rather than after a cancel that may not have landed.
    private func drain(
        _ stream: AsyncStream<LiveTranscriptionEvent>
    ) -> Task<[LiveTranscriptionEvent], Never> {
        Task {
            var received: [LiveTranscriptionEvent] = []
            for await event in stream { received.append(event) }
            return received
        }
    }

    private func micBuffer(startTime: TimeInterval) -> TaggedAudioBuffer {
        TaggedAudioBuffer(
            source: .microphone,
            buffer: AudioFixtures.tone(seconds: 0.032),
            startTime: startTime
        )
    }

    func test_reports_unavailable_and_registers_nothing_for_an_unsupported_locale() async {
        let sut = LiveTranscriptionService()
        let collector = drain(sut.events)

        // "zz-ZZ" is not a real language, so no transcriber model can back it.
        await sut.prepare(sources: [.microphone], locale: Locale(identifier: "zz-ZZ"))
        // Capture keeps running after live captions bail out; those callbacks
        // must find no sink rather than a half-built one.
        for index in 0..<50 { sut.append(micBuffer(startTime: Double(index) * 0.032)) }
        await sut.finish()

        let received = await collector.value
        XCTAssertEqual(received.count, 1, "got \(received)")
        guard case .unavailable(let message) = received.first else {
            return XCTFail("expected .unavailable, got \(String(describing: received.first))")
        }
        XCTAssertTrue(
            message.contains("zz-ZZ"),
            "the notice must name the locale that failed, got \(message)"
        )
    }

    func test_finish_ends_the_event_stream() async {
        let sut = LiveTranscriptionService()
        let collector = drain(sut.events)

        await sut.finish()

        let received = await collector.value
        XCTAssertEqual(received, [], "finish() must terminate events, not stall consumers")
    }

    func test_a_locale_no_model_can_back_is_not_supported() async {
        let nonsense = Locale(identifier: "zz-ZZ")
        let isSupported = await LiveTranscriptionService.isSupported(locale: nonsense)
        let resolved = await LiveTranscriptionService.supportedLocale(equivalentTo: nonsense)

        XCTAssertFalse(isSupported)
        XCTAssertNil(resolved)
    }

    /// Pins that support is decided by asking the framework rather than by any
    /// list of our own. Skipped where the machine advertises no locales at all,
    /// because that is an environment fact and not a defect in this code.
    func test_support_is_decided_by_the_framework_not_by_a_hardcoded_list() async throws {
        let advertised = await SpeechTranscriber.supportedLocales
        try XCTSkipIf(advertised.isEmpty, "this machine advertises no SpeechTranscriber locales")

        for locale in advertised {
            let resolved = await LiveTranscriptionService.supportedLocale(equivalentTo: locale)
            XCTAssertNotNil(resolved, "\(locale.identifier) is advertised but was rejected")
        }
    }

    /// A region variant must resolve to its language equivalent instead of being
    /// refused, which is what `supportedLocale(equivalentTo:)` buys us over an
    /// exact-match lookup against `supportedLocales`.
    func test_an_unlisted_region_resolves_to_a_supported_equivalent() async throws {
        let advertised = await SpeechTranscriber.supportedLocales
        let languages = Set(advertised.compactMap { $0.language.languageCode?.identifier })
        guard let language = languages.sorted().first else {
            throw XCTSkip("this machine advertises no SpeechTranscriber locales")
        }

        let unlistedRegion = Locale(identifier: "\(language)_ZZ")
        let resolved = await LiveTranscriptionService.supportedLocale(equivalentTo: unlistedRegion)
        XCTAssertNotNil(
            resolved,
            "\(unlistedRegion.identifier) shares a language with a supported locale"
        )
    }

    // MARK: - Fake

    func test_fake_delivers_emitted_events_in_order() async {
        let sut = FakeLiveTranscriptionService()
        let collector = drain(sut.events)

        await sut.prepare(sources: [.microphone], locale: Locale(identifier: "ko-KR"))
        sut.emit(.ready)
        sut.emit(.volatile(source: .microphone, text: "안녕", startTime: 0))
        sut.emit(.finalized(source: .microphone, text: "안녕하세요.", startTime: 0))
        await sut.finish()

        let received = await collector.value
        XCTAssertEqual(received, [
            .ready,
            .volatile(source: .microphone, text: "안녕", startTime: 0),
            .finalized(source: .microphone, text: "안녕하세요.", startTime: 0)
        ])
    }

    func test_fake_records_what_its_coordinator_did() async {
        let sut = FakeLiveTranscriptionService()

        await sut.prepare(sources: [.microphone, .systemAudio], locale: Locale(identifier: "ko-KR"))
        sut.append(micBuffer(startTime: 0))
        sut.append(micBuffer(startTime: 0.032))
        await sut.finish()

        XCTAssertEqual(sut.prepareCallCount, 1)
        XCTAssertEqual(sut.preparedSources, [.microphone, .systemAudio])
        XCTAssertEqual(sut.preparedLocale?.identifier, "ko-KR")
        XCTAssertEqual(sut.appendedBuffers.map(\.startTime), [0, 0.032])
        XCTAssertEqual(sut.appendedBuffers.map(\.source), [.microphone, .microphone])
        XCTAssertTrue(sut.didFinish)
    }

    func test_fake_records_appends_from_concurrent_capture_threads() {
        let sut = FakeLiveTranscriptionService()
        let perSource = 200
        let group = DispatchGroup()

        for source in AudioSource.allCases {
            DispatchQueue(label: "test.\(source.rawValue)").async(group: group) {
                for index in 0..<perSource {
                    sut.append(TaggedAudioBuffer(
                        source: source,
                        buffer: AudioFixtures.silence(seconds: 0.001),
                        startTime: Double(index) * 0.032
                    ))
                }
            }
        }
        group.wait()

        XCTAssertEqual(sut.appendedBuffers.count, perSource * AudioSource.allCases.count)
        for source in AudioSource.allCases {
            let times = sut.appendedBuffers.filter { $0.source == source }.map(\.startTime)
            XCTAssertEqual(times, times.sorted(), "\(source.rawValue) buffers were reordered")
        }
    }
}
