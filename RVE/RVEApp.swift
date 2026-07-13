import SwiftUI

@main
struct RVEApp: App {
    @StateObject private var editor = EditorStateMachine()
    @StateObject private var speech = WhisperKitBackend()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(editor)
                .environmentObject(speech)
                .frame(minWidth: 820, minHeight: 620)
                .task {
                    speech.connect(to: editor)
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
