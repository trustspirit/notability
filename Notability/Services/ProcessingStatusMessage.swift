import Foundation

/// What a meeting says when its processing did not finish.
///
/// Gathered in one place because three paths write these: quitting, the store's
/// interrupted-meeting detection at the next launch, and the pipeline's own
/// failure handling. All three describe the same few situations, and each
/// message has to be true of the meeting it is attached to in two specific ways.
///
/// Retry is only offered while `Meeting.canRetryProcessing` holds, so a message
/// that tells the user to retry has to be paired with state that lets them. And
/// the diarized transcription pass is the one charged step per meeting, so a
/// message that leaves out a charge that has already happened, or implies one
/// that will not, is the same defect pointing the other way.
enum ProcessingStatusMessage {
    static let noAudioCaptured = "No audio was captured."

    static let noSpeechRecognised = "The recording contained no recognisable speech."

    /// Quitting ended the recording. The audio files were closed on the way out,
    /// so they can be read, and nothing has been transcribed yet.
    static let quitDuringRecording = """
        Quitting ended this recording before it was transcribed. The audio was saved and \
        can be read, so Retry will transcribe it and generate the notes. Transcription \
        has not run for this meeting yet, so Retry is the first time it is charged.
        """

    /// The process died before the paid pass, and what it left behind reads.
    static let interruptedBeforeTranscription = """
        Notability stopped before this recording was transcribed. The audio was kept and \
        can be read, so Retry will transcribe it and generate the notes. Transcription \
        has not run for this meeting yet, so Retry is the first time it is charged.
        """

    /// The process died after the paid pass. Recorded against the notes stage,
    /// because that is the stage that did not finish and because the transcript
    /// on disk is what makes Retry free.
    static let interruptedBeforeNotes = """
        Notability stopped after this recording was transcribed but before its notes were \
        generated. The transcript is saved and has already been charged for, so Retry only \
        generates the notes and is not charged again.
        """

    /// The process died before the paid pass and left audio nothing can decode.
    /// Deliberately promises no Retry and claims nothing about the disk: the
    /// meeting's `audioDirectory` is cleared alongside this so no Retry is
    /// offered, and reclaiming the files is best-effort.
    static let unreadableAudio = """
        Notability stopped before this recording was transcribed, and the audio it captured \
        was left incomplete: a recording can only be read once its file has been closed, \
        which a crash or a force quit does not do. There is nothing left to transcribe, so \
        this meeting cannot be recovered — you can delete it from the sidebar.
        """

    static let missingAudio = """
        Notability stopped before this recording was transcribed, and no audio was found \
        for it. There is nothing left to transcribe, so this meeting cannot be recovered — \
        you can delete it from the sidebar.
        """

    /// A write failed partway through the recording, so the file on disk stops
    /// short of the meeting. The audio is kept because transcribing part of a
    /// meeting is the user's call to make, not something to do for them.
    static func incompleteWrite(_ error: Error) -> String {
        "The recording is incomplete — saving audio failed partway through "
            + "(\(error.localizedDescription)). Your audio has been kept."
    }
}
