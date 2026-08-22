import XCTest
import AVFoundation
import Combine
@testable import Notability

@MainActor
final class RecordingCoordinatorTests: XCTestCase {

    // MARK: - Starting

    func test_start_transitions_to_recording() async throws {
        let env = makeSUT()
        XCTAssertEqual(env.sut.state, .idle)

        try await env.sut.startRecording()

        guard case .recording = env.sut.state else {
            return XCTFail("Expected .recording, got \(env.sut.state)")
        }
        XCTAssertEqual(env.capture.startCallCount, 1)
    }

    func test_start_fails_when_microphone_is_unavailable() async {
        let env = makeSUT()
        env.capture.isCapturingMicrophone = false

        do {
            try await env.sut.startRecording()
            XCTFail("Expected recording to fail without microphone capture")
        } catch {
            XCTAssertTrue(env.store.allMeetings.isEmpty)
            XCTAssertEqual(env.capture.stopCallCount, 1, "A partial start must be unwound")
            XCTAssertEqual(env.sut.state, .idle)
        }
    }

    func test_start_does_not_create_a_meeting_when_capture_throws() async {
        let env = makeSUT()
        env.capture.startError = StubProcessingError(message: "no input device")

        do {
            try await env.sut.startRecording()
            XCTFail("Expected startCapture's error to propagate")
        } catch {
            XCTAssertTrue(env.store.allMeetings.isEmpty)
            XCTAssertNil(env.sut.currentMeetingId)
        }
    }

    /// `prepare` downloads a ~300 MB model on first run. Recording must begin
    /// while that is still in flight.
    func test_start_returns_while_live_transcription_is_still_preparing() async throws {
        let env = makeSUT()
        env.liveFactory.armsPrepareGate = true

        let returned = expectation(description: "startRecording returns")
        Task {
            try? await env.sut.startRecording()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)

        XCTAssertEqual(env.live.prepareCallCount, 1)
        XCTAssertEqual(env.live.prepareReturnCount, 0, "prepare must still be running")
        guard case .recording = env.sut.state else {
            return XCTFail("Expected .recording while prepare is still running, got \(env.sut.state)")
        }
        env.live.releasePrepare()
    }

    func test_start_prepares_both_sources_with_the_configured_locale() async throws {
        let env = makeSUT()
        // Gated so the arguments can be read at a point where `prepare` is
        // provably still inside the call, rather than waiting for it to return.
        env.liveFactory.armsPrepareGate = true
        let returned = expectation(description: "startRecording returns")
        Task {
            try? await env.sut.startRecording()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)

        XCTAssertEqual(env.live.preparedSources, AudioSource.allCases)
        XCTAssertEqual(
            env.live.preparedLocale?.identifier,
            ModelSettings.shared.effectiveTranscriptionLocaleIdentifier
        )
        env.live.releasePrepare()
    }

    func test_second_recording_uses_a_fresh_live_transcription_service() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        let first = env.live
        await env.sut.stopRecording()

        try await env.sut.startRecording()

        XCTAssertEqual(env.liveFactory.created.count, 2)
        XCTAssertFalse(env.live === first, "A finished service cannot be reused for a second recording")
        XCTAssertTrue(first.didFinish)
    }

    // MARK: - Live captions

    func test_volatile_event_shows_provisional_caption_with_speaker() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.volatile(source: .microphone, text: "안녕", startTime: 0))

        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 1 && $0[0].text == "안녕" },
            description: "provisional caption appears"
        )
        XCTAssertEqual(env.sut.visibleLiveTranscript.first?.speaker, "나")
    }

    func test_volatile_event_replaces_previous_volatile_for_same_source() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.volatile(source: .microphone, text: "안녕", startTime: 0))
        env.live.emit(.volatile(source: .microphone, text: "안녕하세요", startTime: 0))

        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 1 && $0[0].text == "안녕하세요" },
            description: "provisional caption is replaced, not appended"
        )
    }

    func test_finalized_event_clears_the_volatile_row_for_its_source() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.volatile(source: .microphone, text: "제 의견", startTime: 0))
        env.live.emit(.finalized(source: .microphone, text: "제 의견입니다.", startTime: 0))

        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 1 && $0[0].text == "제 의견입니다." },
            description: "finalized row replaces its own volatile row"
        )
    }

    func test_two_sources_produce_separate_rows() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.finalized(source: .microphone, text: "제 의견입니다.", startTime: 0))
        env.live.emit(.finalized(source: .systemAudio, text: "동의합니다.", startTime: 1))

        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 2 },
            description: "both sources get a row"
        )
        XCTAssertEqual(env.sut.visibleLiveTranscript.map(\.speaker), ["나", "상대방"])
    }

    func test_volatile_rows_sort_after_finalized_rows() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        // A provisional row whose timestamp precedes an already-finalized row
        // must not push the finished text down the view.
        env.live.emit(.finalized(source: .microphone, text: "확정된 줄", startTime: 10))
        env.live.emit(.volatile(source: .systemAudio, text: "임시 줄", startTime: 2))

        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 2 },
            description: "both rows visible"
        )
        XCTAssertEqual(env.sut.visibleLiveTranscript.map(\.text), ["확정된 줄", "임시 줄"])
    }

    func test_download_progress_is_shown_then_cleared_when_ready() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.downloading(progress: 0.42))
        await waitUntil(
            env.sut.$liveCaptionNotice,
            satisfies: { $0 == "Downloading the on-device speech model… 42%" },
            description: "download notice appears"
        )

        env.live.emit(.ready)
        await waitUntil(
            env.sut.$liveCaptionNotice,
            satisfies: { $0 == nil },
            description: "download notice clears"
        )
    }

    func test_unavailable_event_surfaces_notice_without_failing() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.unavailable("Model not installed"))

        await waitUntil(
            env.sut.$liveCaptionNotice,
            satisfies: { $0 == "Model not installed" },
            description: "unavailable notice appears"
        )
        guard case .recording = env.sut.state else {
            return XCTFail("Live caption failure must not stop the recording")
        }
    }

    /// The service reports one source failing and then `.ready` for the other.
    /// Clearing the failure on `.ready` would hide a half-working caption tier.
    func test_ready_does_not_clear_an_unavailable_notice() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        env.live.emit(.unavailable("Live captions unavailable for systemAudio"))
        env.live.emit(.ready)

        await waitUntil(
            env.sut.$liveCaptionNotice,
            satisfies: { $0 == "Live captions unavailable for systemAudio" },
            description: "unavailable notice survives .ready"
        )
        // Give the .ready event a chance to be mishandled before asserting.
        await drainMainQueue()
        XCTAssertEqual(env.sut.liveCaptionNotice, "Live captions unavailable for systemAudio")
    }

    // MARK: - Buffer fan-out

    func test_capture_buffers_reach_both_consumers_without_a_thread_hop() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()

        let captureThread = env.capture.emitFromCaptureThread(
            source: .microphone,
            buffer: AudioFixtures.tone(seconds: 0.1),
            startTime: 0
        )

        // No wait: a correct fan-out is synchronous, so both consumers have
        // already been called by the time emit returns. Waiting here would let a
        // thread-hopping implementation pass.
        XCTAssertEqual(env.live.appendedBuffers.count, 1)
        XCTAssertEqual(env.live.appendedBuffers.first?.source, .microphone)
        XCTAssertEqual(env.live.appendThreadIDs, [captureThread])

        let micWriter = try XCTUnwrap(env.recorders?.writer(for: .microphone))
        XCTAssertEqual(micWriter.appendedFrameCounts, [1_600])
        XCTAssertEqual(micWriter.appendThreadIDs, [captureThread])
    }

    func test_buffers_are_routed_to_the_recorder_for_their_own_source() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()

        env.capture.emitFromCaptureThread(
            source: .systemAudio,
            buffer: AudioFixtures.tone(seconds: 0.1),
            startTime: 0
        )

        XCTAssertEqual(env.recorders?.writer(for: .systemAudio)?.appendedFrameCounts, [1_600])
        XCTAssertEqual(env.recorders?.writer(for: .microphone)?.appendedFrameCounts, [])
    }

    func test_per_source_buffer_order_is_preserved() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()

        for index in 1...5 {
            env.capture.emitFromCaptureThread(
                source: .microphone,
                buffer: AudioFixtures.tone(seconds: Double(index) * 0.01),
                startTime: Double(index)
            )
        }

        XCTAssertEqual(
            env.live.appendedBuffers.map(\.startTime),
            [1, 2, 3, 4, 5],
            "Reordering a source's buffers kills its captions for the rest of the recording"
        )
        XCTAssertEqual(
            env.recorders?.writer(for: .microphone)?.appendedFrameCounts,
            [160, 320, 480, 640, 800]
        )
    }

    func test_no_buffer_is_routed_after_stop() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()
        await env.sut.stopRecording()

        env.capture.emitFromCaptureThread(
            source: .microphone,
            buffer: AudioFixtures.tone(seconds: 0.1),
            startTime: 0
        )

        XCTAssertEqual(env.live.appendedBuffers.count, 0)
        XCTAssertEqual(env.recorders?.writer(for: .microphone)?.appendedFrameCounts, [])
    }

    func test_audio_level_reaches_the_main_actor() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()

        env.capture.emitFromCaptureThread(
            source: .microphone,
            buffer: AudioFixtures.tone(seconds: 0.1),
            startTime: 0
        )

        await waitUntil(
            env.sut.$audioLevel,
            satisfies: { $0 > 0 },
            description: "level meter is fed"
        )
    }

    // MARK: - Stopping and processing

    func test_stop_replaces_transcript_with_diarized_result_and_reaches_done() async throws {
        let env = makeSUT()
        env.final.result = DiarizedTranscription(
            chunks: [
                TranscriptChunk(timestamp: 0, text: "확정된 문장입니다.", speaker: "나"),
                TranscriptChunk(timestamp: 5, text: "네 좋습니다.", speaker: "A")
            ],
            billedSeconds: 42
        )
        try await env.sut.startRecording()
        env.live.emit(.finalized(source: .microphone, text: "임시 자막", startTime: 0))
        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 1 },
            description: "live caption lands before stopping"
        )
        env.emitSpeech()

        await env.sut.stopRecording()

        guard case .done(let id) = env.sut.state else {
            return XCTFail("Expected .done, got \(env.sut.state)")
        }
        let meeting = try XCTUnwrap(env.store.fetch(id: id))
        XCTAssertEqual(meeting.transcript.map(\.text), ["확정된 문장입니다.", "네 좋습니다."])
        XCTAssertEqual(meeting.transcript.map(\.speaker), ["나", "A"])
        XCTAssertEqual(meeting.billedSeconds, 42)
        XCTAssertEqual(env.sut.visibleLiveTranscript.map(\.text), ["확정된 문장입니다.", "네 좋습니다."])
    }

    /// On-device captions are display-only. Persisting them would make
    /// "this meeting already has a transcript" ambiguous, and a retry would then
    /// generate notes from rough caption text instead of the diarized pass.
    func test_live_captions_are_never_persisted_to_the_meeting() async throws {
        let env = makeSUT()
        env.final.error = StubProcessingError(message: "rate limited")
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.live.emit(.finalized(source: .microphone, text: "임시 자막", startTime: 0))
        await waitUntil(
            env.sut.$visibleLiveTranscript,
            satisfies: { $0.count == 1 },
            description: "live caption lands"
        )
        env.emitSpeech()

        await env.sut.stopRecording()

        XCTAssertTrue(try XCTUnwrap(env.store.fetch(id: meetingId)).transcript.isEmpty)
    }

    func test_stop_finishes_live_transcription_and_the_recorders() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()

        await env.sut.stopRecording()

        XCTAssertTrue(env.live.didFinish)
        XCTAssertEqual(env.capture.stopCallCount, 1)
        for source in AudioSource.allCases {
            XCTAssertEqual(env.recorders?.writer(for: source)?.didFinish, true)
        }
    }

    /// `stopRecording` must not wait on an asset download, and must not leave
    /// `prepare` running against a service it has already finished.
    func test_stop_while_preparing_cancels_prepare_and_still_finishes() async throws {
        let env = makeSUT()
        env.liveFactory.armsPrepareGate = true
        let started = expectation(description: "startRecording returns")
        Task {
            try? await env.sut.startRecording()
            started.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)

        let prepareReturned = expectation(description: "prepare unwinds")
        env.live.onPrepareReturn = { prepareReturned.fulfill() }

        await env.sut.stopRecording()

        XCTAssertTrue(env.live.didFinish, "finish() must run even while prepare is in flight")
        await fulfillment(of: [prepareReturned], timeout: 5)
        XCTAssertTrue(env.live.prepareWasCancelled)
    }

    func test_audio_is_deleted_after_successful_note_generation() async throws {
        let env = makeSUT()
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "완료", speaker: "나")],
            billedSeconds: 10
        )
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()

        await env.sut.stopRecording()

        XCTAssertEqual(env.sut.state, .done(meetingId: meetingId))
        let audioDirectory = env.audioRoot.appendingPathComponent(meetingId.uuidString)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioDirectory.path))
        XCTAssertNil(env.store.fetch(id: meetingId)?.audioDirectory)
    }

    func test_audio_is_retained_when_transcription_fails() async throws {
        let env = makeSUT()
        env.final.error = StubProcessingError(message: "rate limited")
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()

        await env.sut.stopRecording()

        guard case .failed = env.sut.state else {
            return XCTFail("Expected .failed, got \(env.sut.state)")
        }
        let meeting = try XCTUnwrap(env.store.fetch(id: meetingId))
        XCTAssertEqual(meeting.transcriptionError, "rate limited")
        XCTAssertEqual(env.notes.callCount, 0, "Notes must not be generated without a transcript")
        let directory = try XCTUnwrap(meeting.audioDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_audio_is_retained_when_note_generation_fails() async throws {
        let env = makeSUT()
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "본문", speaker: "나")],
            billedSeconds: 5
        )
        env.notes.error = StubProcessingError(message: "notes exploded")
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()

        await env.sut.stopRecording()

        let meeting = try XCTUnwrap(env.store.fetch(id: meetingId))
        XCTAssertEqual(meeting.notesGenerationError, "notes exploded")
        XCTAssertEqual(meeting.transcript.count, 1, "Transcript must survive a note failure")
        let directory = try XCTUnwrap(meeting.audioDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    func test_empty_transcription_result_is_treated_as_a_failure() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()

        await env.sut.stopRecording()

        guard case .failed = env.sut.state else {
            return XCTFail("Expected .failed, got \(env.sut.state)")
        }
        XCTAssertEqual(env.notes.callCount, 0)
        XCTAssertNotNil(env.store.fetch(id: meetingId)?.audioDirectory)
    }

    func test_recording_with_no_audio_fails_before_the_paid_call() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()

        await env.sut.stopRecording()

        guard case .failed = env.sut.state else {
            return XCTFail("Expected .failed, got \(env.sut.state)")
        }
        XCTAssertEqual(env.final.callCount, 0, "An empty recording must not be uploaded")
    }

    /// A write failure means the file on disk is truncated. Transcribing it
    /// automatically would bill for, and hand back, a silently incomplete
    /// transcript.
    func test_write_failure_stops_before_transcribing_and_keeps_audio() async throws {
        let env = makeSUT(useFakeRecorders: true)
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.recorders?.writer(for: .microphone)?.writeError =
            StubProcessingError(message: "disk full")

        await env.sut.stopRecording()

        guard case .failed = env.sut.state else {
            return XCTFail("Expected .failed, got \(env.sut.state)")
        }
        XCTAssertEqual(env.final.callCount, 0)
        let meeting = try XCTUnwrap(env.store.fetch(id: meetingId))
        XCTAssertNotNil(meeting.audioDirectory)
        XCTAssertEqual(
            meeting.transcriptionError?.contains("disk full"),
            true,
            "The user needs to know why, got \(meeting.transcriptionError ?? "nil")"
        )
    }

    func test_microphone_only_recording_still_mixes_and_transcribes() async throws {
        let env = makeSUT()
        env.capture.isCapturingSystemAudio = false
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "혼자 말함", speaker: "나")],
            billedSeconds: 3
        )
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech(sources: [.microphone])

        await env.sut.stopRecording()

        XCTAssertEqual(env.sut.state, .done(meetingId: meetingId))
        XCTAssertEqual(env.final.callCount, 1)
        XCTAssertEqual(
            env.final.receivedSpeakerReferences,
            [nil],
            "Too short for a reference window; the call must still go out"
        )
    }

    // MARK: - Microphone loss mid-recording

    func test_losing_the_microphone_mid_recording_stops_and_keeps_the_audio() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()

        env.capture.isCapturingMicrophone = false

        await waitUntil(
            env.sut.$state,
            satisfies: { if case .recording = $0 { return false } else { return true } },
            description: "recording ends when the local voice is lost"
        )
        XCTAssertEqual(env.capture.stopCallCount, 1)
        XCTAssertNotNil(
            env.sut.recordingInterruptedNotice,
            "Silently handing back a half recording is the worst outcome"
        )
        XCTAssertNotNil(env.store.fetch(id: meetingId)?.audioDirectory)
    }

    /// The capture service publishes availability through a main-queue hop while
    /// its getter updates immediately, so a subscriber's replayed value can still
    /// be the pre-start `false`. Acting on that would abort every recording.
    func test_replayed_pre_start_unavailability_does_not_stop_the_recording() async throws {
        let env = makeSUT()
        env.capture.seedMicrophoneAvailability(false)

        try await env.sut.startRecording()
        await drainMainQueue()

        guard case .recording = env.sut.state else {
            return XCTFail("Expected .recording, got \(env.sut.state)")
        }
        XCTAssertNil(env.sut.recordingInterruptedNotice)
    }

    func test_echo_cancellation_state_is_published() async throws {
        let env = makeSUT()
        env.capture.isEchoCancellationEnabled = false

        try await env.sut.startRecording()

        // Without it the far end is in both tracks, so it gets transcribed and
        // billed twice — the user needs to be able to see that.
        XCTAssertFalse(env.sut.echoCancellationEnabled)
    }

    func test_deleting_the_meeting_mid_recording_leaves_the_ui_idle() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.store.delete(id: meetingId)

        await env.sut.stopRecording()

        XCTAssertEqual(env.sut.state, .idle)
    }

    func test_starting_twice_is_refused() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)

        do {
            try await env.sut.startRecording()
            XCTFail("A second recording would orphan the first one's recorders")
        } catch {
            XCTAssertEqual(env.sut.currentMeetingId, meetingId)
            XCTAssertEqual(env.capture.startCallCount, 1)
        }
    }

    func test_system_audio_availability_is_published() async throws {
        let env = makeSUT()
        try await env.sut.startRecording()
        XCTAssertTrue(env.sut.systemAudioAvailable)

        env.capture.isCapturingSystemAudio = false

        await waitUntil(
            env.sut.$systemAudioAvailable,
            satisfies: { $0 == false },
            description: "losing system audio is surfaced"
        )
        guard case .recording = env.sut.state else {
            return XCTFail("Losing system audio must not stop the recording")
        }
    }

    // MARK: - Retry

    func test_retry_after_note_failure_reuses_the_transcript_it_already_paid_for() async throws {
        let env = makeSUT()
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "본문", speaker: "나")],
            billedSeconds: 5
        )
        env.notes.error = StubProcessingError(message: "notes exploded")
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()
        await env.sut.stopRecording()
        XCTAssertEqual(env.final.callCount, 1)

        env.notes.error = nil
        await env.sut.retryProcessing(meetingId: meetingId).value

        XCTAssertEqual(env.sut.state, .done(meetingId: meetingId))
        XCTAssertEqual(env.final.callCount, 1, "The diarized pass already succeeded and is billed")
        XCTAssertEqual(env.notes.receivedTranscripts.last?.first?.text, "본문")
        let meeting = try XCTUnwrap(env.store.fetch(id: meetingId))
        XCTAssertNotNil(meeting.notes)
        XCTAssertNil(meeting.notesGenerationError)
        XCTAssertNil(meeting.audioDirectory)
    }

    func test_retry_after_transcription_failure_runs_the_transcription_again() async throws {
        let env = makeSUT()
        env.final.error = StubProcessingError(message: "rate limited")
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()
        await env.sut.stopRecording()
        XCTAssertEqual(env.final.callCount, 1)

        env.final.error = nil
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "두 번째 시도", speaker: "나")],
            billedSeconds: 7
        )
        await env.sut.retryProcessing(meetingId: meetingId).value

        XCTAssertEqual(env.sut.state, .done(meetingId: meetingId))
        XCTAssertEqual(env.final.callCount, 2)
        let meeting = try XCTUnwrap(env.store.fetch(id: meetingId))
        XCTAssertEqual(meeting.transcript.first?.text, "두 번째 시도")
        XCTAssertNil(meeting.transcriptionError)
        XCTAssertNil(meeting.audioDirectory)
    }

    func test_retry_after_success_does_nothing() async throws {
        let env = makeSUT()
        env.final.result = DiarizedTranscription(
            chunks: [TranscriptChunk(timestamp: 0, text: "완료", speaker: "나")],
            billedSeconds: 10
        )
        try await env.sut.startRecording()
        let meetingId = try XCTUnwrap(env.sut.currentMeetingId)
        env.emitSpeech()
        await env.sut.stopRecording()

        await env.sut.retryProcessing(meetingId: meetingId).value

        XCTAssertEqual(env.final.callCount, 1)
        XCTAssertEqual(env.notes.callCount, 1)
        XCTAssertEqual(env.sut.state, .done(meetingId: meetingId))
    }

    func test_retry_for_an_unknown_meeting_does_nothing() async {
        let env = makeSUT()
        await env.sut.retryProcessing(meetingId: UUID()).value
        XCTAssertEqual(env.final.callCount, 0)
        XCTAssertEqual(env.sut.state, .idle)
    }

    // MARK: - Helpers

    private struct Environment {
        let sut: RecordingCoordinator
        let capture: MockAudioCaptureService
        let liveFactory: FakeLiveTranscriptionFactory
        let final: MockFinalTranscriptionService
        let notes: MockNoteGenerationService
        let store: MeetingStore
        let audioRoot: URL
        let recorders: FakeRecorderRegistry?

        @MainActor
        var live: FakeLiveTranscriptionService { liveFactory.latest }

        /// Emits enough real audio for the mixer to have something to work with.
        /// Half a second is far below the speaker-reference window, so the
        /// reference stays nil and no test depends on the extractor's heuristics.
        @MainActor
        func emitSpeech(sources: [AudioSource] = AudioSource.allCases) {
            for source in sources {
                capture.emitFromCaptureThread(
                    source: source,
                    buffer: AudioFixtures.tone(seconds: 0.5),
                    startTime: 0
                )
            }
        }
    }

    private func makeSUT(useFakeRecorders: Bool = false) -> Environment {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let storeDirectory = root.appendingPathComponent("store")
        let audioRoot = root.appendingPathComponent("audio")
        try! FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let store = MeetingStore(storageDirectory: storeDirectory)
        let capture = MockAudioCaptureService()
        let liveFactory = FakeLiveTranscriptionFactory()
        let final = MockFinalTranscriptionService()
        let notes = MockNoteGenerationService()
        let recorders = useFakeRecorders ? FakeRecorderRegistry() : nil

        let sut = RecordingCoordinator(
            audioCapture: capture,
            makeLiveTranscription: { liveFactory.make() },
            finalTranscription: final,
            noteGeneration: notes,
            store: store,
            audioRootDirectory: audioRoot,
            makeSessionRecorder: recorders?.make ?? { directory, source, sampleRate in
                try SessionRecorder(directory: directory, source: source, sampleRate: sampleRate)
            }
        )
        return Environment(
            sut: sut,
            capture: capture,
            liveFactory: liveFactory,
            final: final,
            notes: notes,
            store: store,
            audioRoot: audioRoot,
            recorders: recorders
        )
    }
}

/// Hands out `FakeSessionAudioWriter`s and keeps them, so a test can assert on
/// what the buffer fan-out wrote without decoding AAC.
@MainActor
final class FakeRecorderRegistry {
    private var writers: [AudioSource: FakeSessionAudioWriter] = [:]

    func writer(for source: AudioSource) -> FakeSessionAudioWriter? { writers[source] }

    func make(directory: URL, source: AudioSource, sampleRate: Double) throws -> SessionAudioWriting {
        let writer = FakeSessionAudioWriter(
            url: directory.appendingPathComponent("\(source.fileBaseName).m4a")
        )
        writers[source] = writer
        return writer
    }
}
