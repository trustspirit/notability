# Notability

A macOS menu bar app that records your meetings — your own voice plus the audio from any meeting tool, Zoom, Google Meet, or Teams, with no plugins — and turns them into speaker-separated transcripts and AI-generated notes.

![macOS](https://img.shields.io/badge/macOS-26.0%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)

## Features

- **Microphone and system audio capture** — ScreenCaptureKit records any app's audio without extra drivers, alongside your own voice from the microphone. macOS's echo canceller is enabled on the microphone to keep the far end from being recorded twice when you are on speakers, and the app tells you when it could not be.
- **Live captions, on-device** — Apple's SpeechAnalyzer transcribes as you speak. No audio leaves your Mac for captions, and there is no per-minute cost.
- **Speaker-separated final transcript** — When the meeting ends, the full recording is transcribed once with `gpt-4o-transcribe-diarize`, which labels each turn. Seeing the whole meeting at once gives far better punctuation and terminology than transcribing short fragments.
- **AI-generated notes** — `gpt-5.5` by default then reads the transcript and produces a 2–3 sentence summary, action items with assignee and due date, and the key decisions made.
- **Audio kept until notes succeed** — If transcription or note generation fails, the recording is retained so you can retry without re-recording.
- **Meeting history** — Every transcript and note is saved locally and accessible from the sidebar.

## Installation

### Requirements

- macOS 26.0 (Tahoe) or later
- OpenAI API Key ([get one here](https://platform.openai.com/api-keys))

### Download

1. Download `Notability.zip` from the [Releases](../../releases/latest) page
2. Unzip and move `Notability.app` to `/Applications`
3. Run this command in Terminal to remove the quarantine flag:
   ```bash
   xattr -cr /Applications/Notability.app
   ```
4. Open `Notability.app`

> **Note:** This app is not notarized by Apple. macOS will show "damaged and can't be opened"
> if you skip step 3 — this is a Gatekeeper false positive, not an actual corruption.

### First-time Setup

1. Click the mic icon in the menu bar → **Settings...**
2. Enter your OpenAI API Key and click Save
3. Allow **Microphone** access when macOS asks — your own voice is part of every recording, so
   Notability will not record without it
4. Start a recording. Screen Recording access is only checked at that point; if it is missing,
   Notability offers to open System Settings and relaunch. Enable Notability under
   Privacy & Security → Screen Recording
5. Without Screen Recording, recording still works — it just captures your microphone alone

> **Note:** The first recording in a given language downloads Apple's on-device speech model,
> which can take a few minutes. Recording starts immediately and captions appear once the
> download finishes; the final transcript does not depend on it.

## Usage

| Action | Description |
|--------|-------------|
| Click 🎙 → Start Recording | Start capturing meeting audio |
| Click the red ⏺ icon | Stop recording and generate notes |
| ⏳ icon | AI is generating your notes |
| Completion notification | Click to view the finished notes |

> **Note:** The final transcript is one upload, which caps a meeting at roughly 2 hours 20
> minutes. Longer recordings fail with a "too long" message and are kept on disk.

## Tech Stack

| Layer | Technology |
|-------|------------|
| UI | SwiftUI (macOS 26+) |
| Audio capture | ScreenCaptureKit (system audio), AVAudioEngine (microphone) |
| Audio encoding | AVFoundation |
| Live transcription | Apple Speech (`SpeechAnalyzer`, on-device) |
| Final transcription | OpenAI `gpt-4o-transcribe-diarize` |
| Note generation | OpenAI gpt-5.5 (configurable) |
| Storage | Local JSON (`~/Library/Application Support/Notability`) |
| API key | Owner-only file in `~/Library/Application Support/Notability/credentials` |

## Building from Source

```bash
# Requires xcodegen
brew install xcodegen

git clone https://github.com/trustspirit/notability
cd notability
xcodegen generate
open Notability.xcodeproj
```

## Privacy

- Live captions are produced entirely on your Mac. No audio is sent anywhere for them.
- The recording is uploaded to the OpenAI API once, after the meeting ends, for the final
  transcript; the transcript is then sent for note generation (subject to OpenAI's Privacy Policy).
- The recording is deleted from disk as soon as notes are generated successfully. It is kept only
  when something failed and you may want to retry.
- Meeting notes and transcripts are stored locally on your device only.
- Your API key is stored with owner-only file permissions in
  `~/Library/Application Support/Notability/credentials` rather than the Keychain, because ad-hoc
  signed builds get a new Keychain identity on every update and stored keys appear to vanish.

## License

MIT
