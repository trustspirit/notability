import Foundation

/// What quitting has to do, decided from the pipeline state alone.
///
/// Separate from `AppDelegate` because `applicationShouldTerminate` cannot be
/// driven from a test: it needs a live `NSApplication` and it blocks on a modal
/// alert. What is worth testing is which prompt each state produces, what its
/// buttons say, and what each button does — and those are exactly the places
/// where a wrong answer costs the user a recording or a second transcription
/// charge.
///
/// Keeping the button titles next to their effects is the point of the shape.
/// The defect this replaces was a button that said it would discard the session
/// and then left the meeting and its audio behind, so the string and the
/// behaviour are defined together and asserted together.
enum QuitPolicy {
    static func decision(for state: RecordingState) -> QuitDecision {
        switch state {
        case .idle, .done, .failed:
            // Nothing is running and nothing is half-written: the recording's
            // files were closed when it stopped, and a finished or failed
            // meeting already says what it is.
            return .quitNow

        case .recording:
            return .ask(QuitPrompt(
                messageText: "Recording in Progress",
                informativeText: """
                    Notability is still recording this meeting.

                    Stop & Generate Notes finishes the recording and then waits for the \
                    transcript and the notes, which can take several minutes for a long meeting.

                    Save Audio & Quit closes the recording and quits straight away. The meeting \
                    is saved untranscribed, and Retry processes it whenever you next open \
                    Notability.
                    """,
                choices: [.processRecordingThenQuit, .saveRecordedAudioThenQuit, .continueRecording]
            ))

        case .transcribing:
            // The paid pass is in flight and is charged whether or not its
            // result arrives, so the cost of quitting is a second charge for
            // the same recording. That is the one thing the user needs told.
            return .ask(QuitPrompt(
                messageText: "Transcription in Progress",
                informativeText: """
                    Notability is transcribing this meeting. That request has already been \
                    charged, and quitting now throws its result away.

                    The audio is kept either way, so you can transcribe the meeting again with \
                    Retry — but that is a second charge for the same recording.
                    """,
                choices: [.keepTranscribing, .abandonProcessingAndQuit]
            ))

        case .generatingNotes:
            // The transcript is already on disk, so this stage costs nothing to
            // repeat. Still worth asking about, because the work in flight is
            // lost either way.
            return .ask(QuitPrompt(
                messageText: "Generating Notes",
                informativeText: """
                    Notability is writing the notes for this meeting. The transcript is already \
                    saved, so quitting now throws away only the notes.

                    Retry generates them again without paying for the transcription a second \
                    time.
                    """,
                choices: [.keepGeneratingNotes, .abandonProcessingAndQuit]
            ))
        }
    }
}

enum QuitDecision: Equatable {
    case quitNow
    case ask(QuitPrompt)
}

struct QuitPrompt: Equatable {
    let messageText: String
    let informativeText: String
    /// In button order. The first is the default, which is why the states with
    /// something in flight lead with the choice that keeps it.
    let choices: [QuitChoice]
}

/// A button in the quit prompt. Its title and its effect are defined together
/// so neither can be changed without the other.
enum QuitChoice: Equatable {
    /// Stop recording and run the whole pipeline before quitting.
    case processRecordingThenQuit
    /// Close the recording's audio files and quit, leaving the meeting for Retry.
    case saveRecordedAudioThenQuit
    case continueRecording
    /// Quit and lose whatever the request in flight would have returned.
    case abandonProcessingAndQuit
    case keepTranscribing
    case keepGeneratingNotes

    var buttonTitle: String {
        switch self {
        case .processRecordingThenQuit: return "Stop & Generate Notes"
        case .saveRecordedAudioThenQuit: return "Save Audio & Quit"
        case .continueRecording: return "Continue Recording"
        case .abandonProcessingAndQuit: return "Quit Anyway"
        case .keepTranscribing: return "Keep Transcribing"
        case .keepGeneratingNotes: return "Keep Generating Notes"
        }
    }

    var effect: QuitEffect {
        switch self {
        case .processRecordingThenQuit: return .quitAfter(.stopRecordingAndProcess)
        case .saveRecordedAudioThenQuit: return .quitAfter(.saveRecordedAudio)
        case .continueRecording, .keepTranscribing, .keepGeneratingNotes: return .cancelQuit
        case .abandonProcessingAndQuit: return .quitNow
        }
    }
}

enum QuitEffect: Equatable {
    case quitNow
    case cancelQuit
    /// Run the work, then let termination proceed.
    case quitAfter(QuitWork)
}

enum QuitWork: Equatable {
    case stopRecordingAndProcess
    case saveRecordedAudio
}
