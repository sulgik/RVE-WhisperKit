import SwiftUI

@main
struct RVEApp: App {
    @StateObject private var editor = EditorStateMachine()
    @StateObject private var speech = WhisperKitBackend()
    @StateObject private var focusedInput = FocusedInputBridge()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("RVE Voice Editor", id: "main-window") {
            ContentView()
                .environmentObject(editor)
                .environmentObject(speech)
                .environmentObject(focusedInput)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    speech.connect(to: editor)
                    focusedInput.connect(editor: editor, speech: speech)
                    focusedInput.install()
                    await speech.prepare()
                }
        }
        .commands {
            CommandGroup(after: .textEditing) {
                Button("현재 Draft 확정") { editor.commitDraft() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("현재 Draft 취소") { editor.cancelDraft() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                Text("RVE · 전역 음성 입력기").font(.headline)
                Text(focusedInput.status).font(.caption).foregroundStyle(.secondary)
                
                Divider()
                
                Toggle("붙여넣기 후 Enter 자동 전송", isOn: $focusedInput.autoSend)
                
                Picker("단축키 모드", selection: $focusedInput.pttKeyMode) {
                    ForEach(PTTKeyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                Divider()

                Button("RVE 메인 창 열기") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main-window")
                }

                Button("RVE 종료") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(4)
        } label: {
            Image(systemName: speech.isListening ? "waveform.circle.fill" : "mic.fill")
        }
    }
}
