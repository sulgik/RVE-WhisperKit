import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum PTTKeyMode: String, CaseIterable, Identifiable {
    case anyOption = "Option (⌥) 누르고 있기 (양쪽)"
    case rightOption = "오른쪽 Option (⌥)"
    case leftOption = "왼쪽 Option (⌥)"
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
    @Published var autoSend: Bool = false
    @Published var pttKeyMode: PTTKeyMode = .anyOption {
        didSet {
            reinstallHotkey()
        }
    }

    private weak var editor: EditorStateMachine?
    private weak var speech: WhisperKitBackend?
    private var globalMonitorFlags: Any?
    private var localMonitorFlags: Any?
    private var globalMonitorKeyDown: Any?
    private var localMonitorKeyDown: Any?
    private var globalMonitorKeyUp: Any?
    private var localMonitorKeyUp: Any?
    private var optionSpaceHotkey: OptionSpaceHotkey?
    private var isPTTActive = false

    func connect(editor: EditorStateMachine, speech: WhisperKitBackend) {
        self.editor = editor
        self.speech = speech
    }

    func install() {
        reinstallHotkey()
    }

    private func reinstallHotkey() {
        removeMonitors()
        
        if pttKeyMode == .toggleOptionSpace {
            speech?.onNaturalStop = { [weak self] in
                self?.pasteCompletedSession()
            }
        } else {
            speech?.onNaturalStop = nil
        }
        
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)

        if isTrusted || CGPreflightPostEventAccess() {
            status = "준비됨 (\(pttKeyMode.rawValue)) · 전역 입력 가동 중"
        } else {
            status = "⚠️ 접근성 권한 필요 (시스템 설정 > 손쉬운 사용에서 RVE 허용)"
            CGRequestPostEventAccess()
        }

        switch pttKeyMode {
        case .anyOption:
            installOptionKeyPTT(allowedKeyCodes: [58, 61]) // 58 = Left Option, 61 = Right Option
        case .rightOption:
            installOptionKeyPTT(allowedKeyCodes: [61])
        case .leftOption:
            installOptionKeyPTT(allowedKeyCodes: [58])
        case .optionSpaceHold:
            installOptionSpaceHoldPTT()
        case .toggleOptionSpace:
            installOptionSpaceToggle()
        }

        isInstalled = true
    }

    private func removeMonitors() {
        if let globalMonitorFlags { NSEvent.removeMonitor(globalMonitorFlags) }
        if let localMonitorFlags { NSEvent.removeMonitor(localMonitorFlags) }
        if let globalMonitorKeyDown { NSEvent.removeMonitor(globalMonitorKeyDown) }
        if let localMonitorKeyDown { NSEvent.removeMonitor(localMonitorKeyDown) }
        if let globalMonitorKeyUp { NSEvent.removeMonitor(globalMonitorKeyUp) }
        if let localMonitorKeyUp { NSEvent.removeMonitor(localMonitorKeyUp) }
        
        globalMonitorFlags = nil
        localMonitorFlags = nil
        globalMonitorKeyDown = nil
        localMonitorKeyDown = nil
        globalMonitorKeyUp = nil
        localMonitorKeyUp = nil
        optionSpaceHotkey = nil
    }

    // MARK: - Option Key PTT (Virtual Key 58: Left Option, 61: Right Option)
    private func installOptionKeyPTT(allowedKeyCodes: [UInt16]) {
        let handleEvent: (NSEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if allowedKeyCodes.contains(event.keyCode) {
                    let isPressed = event.modifierFlags.contains(.option)
                    if isPressed && !self.isPTTActive {
                        self.startPTTSession()
                    } else if !isPressed && self.isPTTActive {
                        self.stopPTTSessionAndPaste()
                    }
                }
            }
        }

        globalMonitorFlags = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleEvent)
        localMonitorFlags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleEvent(event)
            return event
        }
    }

    // MARK: - Option + Space Hold PTT
    private func installOptionSpaceHoldPTT() {
        let handleKeyDown: (NSEvent) -> Void = { [weak self] event in
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

        let handleKeyUp: (NSEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                if (event.keyCode == UInt16(kVK_Space) || event.keyCode == UInt16(kVK_Option)) && self.isPTTActive {
                    self.stopPTTSessionAndPaste()
                }
            }
        }

        globalMonitorKeyDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleKeyDown)
        localMonitorKeyDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
            return event
        }

        globalMonitorKeyUp = NSEvent.addGlobalMonitorForEvents(matching: .keyUp, handler: handleKeyUp)
        localMonitorKeyUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            handleKeyUp(event)
            return event
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

    // MARK: - Walkie-Talkie (PTT) Lifecycle
    func startPTTSession() {
        guard let speech else { return }
        isPTTActive = true
        isDictationSession = true
        speech.startPTT()
        status = "🎙️ 말하는 중… (키를 떼면 즉시 변환)"
    }

    func stopPTTSessionAndPaste() {
        guard isPTTActive, let speech else { return }
        isPTTActive = false
        status = "⏳ Whisper AI 변환 및 입력 중…"
        speech.finishPTTAndTranscribe { [weak self] text in
            self?.pasteTextDirectly(text)
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

    private func pasteTextDirectly(_ text: String) {
        guard isDictationSession else { return }
        isDictationSession = false
        
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "인식된 내용이 없습니다"
            return
        }
        copyToPasteboard(trimmed)
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
    }

    private func pasteCompletedSession() {
        guard isDictationSession, let editor else { return }
        isDictationSession = false
        
        let text = editor.insertionSessionText
        guard !text.isEmpty else {
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
