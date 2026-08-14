import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PTTKeyMode: String, CaseIterable, Identifiable {
    case rightOption = "오른쪽 Option (⌥)"
    case optionSpaceHold = "Option + Space (홀드)"
    case toggleOptionSpace = "Option + Space (토글)"
    
    var id: String { rawValue }
}

/// Turns RVE into an opt-in dictation layer for whichever text field is focused.
/// Supports Push-to-Talk (PTT) with zero-silence delay, auto-paste (⌘V), and optional auto-send (Enter).
@MainActor
final class FocusedInputBridge: ObservableObject {
    @Published private(set) var status = "단축키 준비 전"
    @Published private(set) var isInstalled = false
    @Published private(set) var isDictationSession = false
    @Published var autoSend: Bool = true
    @Published var pttKeyMode: PTTKeyMode = .rightOption {
        didSet {
            reinstallHotkey()
        }
    }

    private weak var editor: EditorStateMachine?
    private weak var speech: WhisperKitBackend?
    private var globalMonitorFlags: Any?
    private var globalMonitorKeyDown: Any?
    private var globalMonitorKeyUp: Any?
    private var optionSpaceHotkey: OptionSpaceHotkey?
    private var isPTTActive = false

    func connect(editor: EditorStateMachine, speech: WhisperKitBackend) {
        self.editor = editor
        self.speech = speech
        speech.onNaturalStop = { [weak self] in
            self?.pasteCompletedSession()
        }
    }

    func install() {
        reinstallHotkey()
    }

    private func reinstallHotkey() {
        removeMonitors()
        
        if CGPreflightPostEventAccess() {
            status = "준비됨 (\(pttKeyMode.rawValue)) · 전역 입력 가동 중"
        } else {
            status = "준비됨 · 접근성 권한 필요"
            CGRequestPostEventAccess()
        }

        switch pttKeyMode {
        case .rightOption:
            installRightOptionPTT()
        case .optionSpaceHold:
            installOptionSpaceHoldPTT()
        case .toggleOptionSpace:
            installOptionSpaceToggle()
        }

        isInstalled = true
    }

    private func removeMonitors() {
        if let globalMonitorFlags { NSEvent.removeMonitor(globalMonitorFlags) }
        if let globalMonitorKeyDown { NSEvent.removeMonitor(globalMonitorKeyDown) }
        if let globalMonitorKeyUp { NSEvent.removeMonitor(globalMonitorKeyUp) }
        globalMonitorFlags = nil
        globalMonitorKeyDown = nil
        globalMonitorKeyUp = nil
        optionSpaceHotkey = nil
    }

    // MARK: - Right Option PTT (Virtual Key 61)
    private func installRightOptionPTT() {
        globalMonitorFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if event.keyCode == 61 { // 61 = Right Option on Mac
                    let isPressed = event.modifierFlags.contains(.option)
                    if isPressed && !self.isPTTActive {
                        self.startPTTSession()
                    } else if !isPressed && self.isPTTActive {
                        self.stopPTTSessionAndPaste()
                    }
                }
            }
        }
    }

    // MARK: - Option + Space Hold PTT
    private func installOptionSpaceHoldPTT() {
        globalMonitorKeyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if event.keyCode == UInt16(kVK_Space) && event.modifierFlags.contains(.option) {
                    if !self.isPTTActive {
                        self.startPTTSession()
                    }
                } else {
                    self.speech?.registerTypingActivity()
                }
            }
        }

        globalMonitorKeyUp = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if (event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Option)) && self.isPTTActive {
                    self.stopPTTSessionAndPaste()
                }
            }
        }
    }

    // MARK: - Option + Space Toggle
    private func installOptionSpaceToggle() {
        optionSpaceHotkey = OptionSpaceHotkey(
            onShortcut: { [weak self] in self?.toggleDictation() },
            onTyping: { [weak self] in self?.speech?.registerTypingActivity() }
        )
        _ = optionSpaceHotkey?.start()
    }

    // MARK: - PTT Lifecycle
    func startPTTSession() {
        guard let editor, let speech else { return }
        isPTTActive = true
        editor.beginInsertionSession()
        isDictationSession = true
        speech.start()
        status = "🎙️ 말하는 중… (키를 떼면 즉시 변환)"
    }

    func stopPTTSessionAndPaste() {
        guard isPTTActive, let speech else { return }
        isPTTActive = false
        status = "⏳ 변환 및 입력 중…"
        speech.finishAndTranscribeFinal { [weak self] in
            self?.pasteCompletedSession()
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
            status = "인식된 내용이 없습니다"
            return
        }
        copyToPasteboard(text)
        if hasPastePermission() {
            postPasteShortcut()
            if autoSend {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.postReturnKey()
                    self?.status = "입력창에 붙여넣고 Enter 전송 완료"
                }
            } else {
                status = "현재 입력창에 붙여넣음"
            }
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

    private func postReturnKey() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true) // 36 = Return
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
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
