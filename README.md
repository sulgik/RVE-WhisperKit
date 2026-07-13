# RVE · WhisperKit macOS MVP

Voice-first editor using WhisperKit locally on Apple Silicon.

## Requirements
- Apple Silicon Mac
- macOS 14+
- Xcode 16+
- Internet on the first run to download the selected Core ML model

## Run
1. Open `RVE.xcodeproj`.
2. Wait for Swift Package Manager to resolve `argmax-oss-swift`.
3. Select your development team under Signing & Capabilities.
4. Run with `⌘R` and allow microphone access.
5. Start with `tiny`; switch to `base` for better Korean recognition.

## Realtime behavior
Whisper is not a token-streaming model by itself. This MVP records continuously and transcribes a rolling 10-second window every ~700 ms. The editor receives each hypothesis immediately and replays it from a segment seed, so partial revisions do not duplicate text.

## Voice editing phrases
- `아니 다시`, `다시 말할게`, `처음부터 다시`: rollback current draft
- `여기까지`, `문장 확정`, `확정해`: commit
- `새 문단`, `다음 문단`: commit as a new paragraph

## Architecture
- `WhisperKitBackend.swift`: replaceable local ASR backend
- `EditorStateMachine.swift`: deterministic Draft/Commit/Rollback state machine
- `ContentView.swift`: SwiftUI editor

## Known MVP limitations
- Rolling-window Whisper inference can repeat or revise several words.
- First model load downloads model files and can take time.
- This project was generated outside macOS, so run it once in Xcode and report any package API mismatch with the exact compiler error.
