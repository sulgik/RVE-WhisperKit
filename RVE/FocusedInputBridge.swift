import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Turns RVE into an opt-in dictation layer for whichever text field is focused.
/// It deliberately does not identify or automate a particular app: the user chooses
/// the destination by focusing its input field before pressing the shortcut.
@MainActor
final class FocusedInputBridge: ObservableObject {
    @Published private(set) var status = "단축키 준비 전"
    @Published private(set) var isInstalled = false
    @Published private(set) var isDictationSession = false

    private weak var editor: EditorStateMachine?
    private weak var speech: WhisperKitBackend?
    private var hotkey: OptionSpaceHotkey?

    func connect(editor: EditorStateMachine, speech: WhisperKitBackend) {
        self.editor = editor
        self.speech = speech
        speech.onNaturalStop = { [weak self] in
            self?.pasteCompletedSession()
        }
    }

    func install() {
        if hotkey == nil {
            hotkey = OptionSpaceHotkey(
                onShortcut: { [weak self] in self?.toggleDictation() },
                onTyping: { [weak self] in self?.speech?.registerTypingActivity() }
            )
        }

        guard hotkey?.start() == true else {
            status = "단축키 시작 실패"
            return
        }

        isInstalled = true
        if CGPreflightPostEventAccess() {
            status = "⌥ Space 준비됨 · 무음이면 자동 붙여넣기"
        } else {
            status = "⌥ Space 준비됨 · 붙여넣기 권한 필요"
            CGRequestPostEventAccess()
        }
    }

    func toggleDictation() {
        guard let editor, let speech else { return }

        if speech.isListening {
            speech.stop()
            pasteCompletedSession()
        } else {
            editor.beginInsertionSession()
            isDictationSession = true
            speech.start()
            status = "듣는 중 · 무음이면 자동 붙여넣기"
        }
    }

    private func pasteCompletedSession() {
        guard isDictationSession, let editor else { return }
        let text = editor.insertionSessionText
        guard !text.isEmpty else {
            isDictationSession = false
            status = "인식된 내용이 없어 붙여넣지 않았습니다"
            return
        }
        copyToPasteboard(text)
        if hasPastePermission() {
            postPasteShortcut()
            status = "현재 입력창에 붙여넣음 · 전송은 직접 하세요"
        } else {
            status = "클립보드에 복사됨 · 대상 앱에서 ⌘V"
        }
        isDictationSession = false
        editor.finishInsertionSession()
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func postPasteShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private func hasPastePermission() -> Bool {
        guard CGPreflightPostEventAccess() else {
            CGRequestPostEventAccess()
            return false
        }
        return true
    }
}

private final class OptionSpaceHotkey {
    private let onShortcut: () -> Void
    private let onTyping: () -> Void
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var typingMonitor: Any?

    init(onShortcut: @escaping () -> Void, onTyping: @escaping () -> Void) {
        self.onShortcut = onShortcut
        self.onTyping = onTyping
    }

    func start() -> Bool {
        guard hotkey == nil else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotkey,
            1,
            &eventType,
            context,
            &handler
        ) == noErr else {
            return false
        }

        var hotkey: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x52564531), id: 1) // "RVE1"
        guard RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotkey
        ) == noErr else {
            if let handler { RemoveEventHandler(handler) }
            return false
        }

        self.handler = handler
        self.hotkey = hotkey
        // This is best-effort: macOS may require Input Monitoring before it
        // exposes other apps' key events. The shortcut itself does not depend on it.
        typingMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            DispatchQueue.main.async { self?.onTyping() }
        }
        return true
    }

    deinit {
        if let typingMonitor { NSEvent.removeMonitor(typingMonitor) }
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private static let handleHotkey: EventHandlerUPP = { _, _, userInfo in
        guard let userInfo else { return noErr }
        let controller = Unmanaged<OptionSpaceHotkey>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { controller.onShortcut() }
        return noErr
    }
}
