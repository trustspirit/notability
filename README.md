# MeetingScribe

macOS 메뉴바 앱으로, Zoom · Google Meet · Teams 등 어떤 미팅 툴에서도 **별도 플러그인 없이** 시스템 오디오를 캡처하고 AI가 미팅 노트를 자동으로 정리해줍니다.

![macOS](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)

## 기능

- **시스템 오디오 캡처** — ScreenCaptureKit으로 어떤 앱의 소리도 캡처 (별도 드라이버 불필요)
- **실시간 전사** — 30초 청크 단위로 OpenAI `gpt-4o-transcribe`에 전송, 미팅 중 transcript 실시간 표시
- **AI 노트 생성** — 미팅 종료 후 `gpt-5.5`가 자동으로 정리
  - **Summary** — 2~3문장 요약
  - **Action Items** — 담당자 · 마감일 포함 할 일 목록
  - **Key Decisions** — 핵심 결정 사항
  - **Full Transcript** — 타임스탬프 포함 전체 스크립트
- **미팅 히스토리** — 모든 노트가 로컬에 저장, 사이드바에서 바로 접근

## 설치

### 요구 사항

- macOS 14.0 (Sonoma) 이상
- OpenAI API Key ([발급 받기](https://platform.openai.com/api-keys))

### 다운로드

1. [Releases](../../releases/latest) 페이지에서 `MeetingScribe.zip` 다운로드
2. 압축 해제 후 `MeetingScribe.app`을 `/Applications`로 이동
3. 처음 실행 시 **우클릭 → 열기** (공증되지 않은 앱 허용)

> **참고:** Apple Developer Program 공증을 거치지 않아 Gatekeeper 경고가 표시됩니다.  
> 시스템 설정 → 개인 정보 보호 및 보안에서 허용하거나 우클릭 → 열기로 실행하세요.

### 첫 실행 설정

1. 메뉴바의 🎙 아이콘 클릭 → **Settings...**
2. OpenAI API Key 입력 후 Save
3. **시스템 설정 → 개인 정보 보호 및 보안 → 화면 기록**에서 MeetingScribe 허용

## 사용 방법

| 동작 | 설명 |
|------|------|
| 🎙 클릭 → Start Recording | 미팅 녹음 시작 |
| ⏺ 빨간 아이콘 클릭 | 녹음 종료 + 노트 생성 시작 |
| ⏳ 아이콘 | AI가 노트 생성 중 |
| 완료 알림 클릭 | 생성된 노트 확인 |

## 기술 스택

| 영역 | 기술 |
|------|------|
| UI | SwiftUI (macOS 14+) |
| 오디오 캡처 | ScreenCaptureKit |
| 오디오 변환 | AVFoundation |
| 전사 | OpenAI gpt-4o-transcribe |
| 노트 생성 | OpenAI gpt-5.5 |
| 저장 | 로컬 JSON (`~/Library/Application Support/MeetingScribe`) |
| API 키 | macOS Keychain |

## 빌드 방법

```bash
# 의존성: xcodegen
brew install xcodegen

git clone https://github.com/trustspirit/MeetingScribe
cd MeetingScribe
xcodegen generate
open MeetingScribe.xcodeproj
```

## 프라이버시

- 모든 오디오 데이터는 OpenAI API로 전송됩니다 (OpenAI Privacy Policy 적용)
- 미팅 노트는 로컬 기기에만 저장됩니다
- API 키는 macOS Keychain에 안전하게 저장됩니다

## 라이선스

MIT
