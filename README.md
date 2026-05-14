# MeetingScribe

A macOS menu bar app that captures system audio from any meeting tool — Zoom, Google Meet, Teams — without plugins, and uses AI to automatically generate meeting notes.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)

## Features

- **System audio capture** — Uses ScreenCaptureKit to record any app's audio without extra drivers
- **Real-time transcription** — Sends audio chunks to OpenAI through either the Audio API (`gpt-4o-transcribe`) or Realtime API (`gpt-realtime-whisper`) and shows the live transcript during the meeting
- **AI-generated notes** — After the meeting ends, `gpt-5.5` automatically produces:
  - **Summary** — 2–3 sentence overview
  - **Action Items** — with assignee and due date
  - **Key Decisions** — major decisions made
  - **Full Transcript** — timestamped
- **Meeting history** — All notes are saved locally and accessible from the sidebar

## Installation

### Requirements

- macOS 14.0 (Sonoma) or later
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
3. When prompted for Screen Recording access, click **"Open Settings & Quit"**
4. Enable Notability in System Settings → Privacy & Security → Screen Recording
5. Relaunch the app — it will open automatically

## Usage

| Action | Description |
|--------|-------------|
| Click 🎙 → Start Recording | Start capturing meeting audio |
| Click the red ⏺ icon | Stop recording and generate notes |
| ⏳ icon | AI is generating your notes |
| Completion notification | Click to view the finished notes |

## Tech Stack

| Layer | Technology |
|-------|------------|
| UI | SwiftUI (macOS 14+) |
| Audio capture | ScreenCaptureKit |
| Audio encoding | AVFoundation |
| Transcription | OpenAI Audio API (`gpt-4o-transcribe`) or Realtime API (`gpt-realtime-whisper`) |
| Note generation | OpenAI gpt-5.5 |
| Storage | Local JSON (`~/Library/Application Support/MeetingScribe`) |
| API key | macOS Keychain |

## Building from Source

```bash
# Requires xcodegen
brew install xcodegen

git clone https://github.com/trustspirit/notability
cd notability
xcodegen generate
open MeetingScribe.xcodeproj
```

## Privacy

- Audio is sent to the OpenAI API for transcription (subject to OpenAI's Privacy Policy)
- Meeting notes are stored locally on your device only
- Your API key is stored securely in the macOS Keychain

## License

MIT
