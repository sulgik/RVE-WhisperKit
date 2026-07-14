import SwiftUI

@main
struct RVEApp: App {
    @StateObject private var editor = EditorStateMachine()
    @StateObject private var speech = WhisperKitBackend()
    @StateObject private var focusedInput = FocusedInputBridge()

    var body: some Scene {
        WindowGroup {
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
    }
}
