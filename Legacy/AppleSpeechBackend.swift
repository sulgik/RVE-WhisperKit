import AVFoundation
import Speech

@MainActor
final class SpeechEngine: NSObject, ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var status = "권한 확인 중"
    @Published private(set) var lastLatencyMS: Int?
    @Published var onDeviceOnly = true

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private weak var editor: EditorStateMachine?
    private var lastAudioAt = ContinuousClock.now
    private var restarting = false

    func connect(to editor: EditorStateMachine) { self.editor = editor }

    func requestPermissions() async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        status = (speech == .authorized && mic) ? "준비됨" : "마이크/음성인식 권한이 필요합니다"
    }

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            status = "음성인식 권한을 허용해 주세요"
            return
        }
        guard recognizer?.isAvailable == true else {
            status = "한국어 음성인식을 사용할 수 없습니다"
            return
        }

        do {
            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                self.lastAudioAt = .now
                self.recognitionRequest?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            status = "듣는 중"
            editor?.beginRecognitionSegment()
            startRecognitionTask()
        } catch {
            status = "오디오 시작 실패: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false
        status = "중지됨"
    }

    private func startRecognitionTask() {
        recognitionTask?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if onDeviceOnly, recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        editor?.beginRecognitionSegment()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let text = result.bestTranscription.formattedString
                    let elapsed = self.lastAudioAt.duration(to: .now)
                    let ms = max(0, Int(Double(elapsed.components.attoseconds) / 1e15)
                        + Int(elapsed.components.seconds) * 1000)
                    self.lastLatencyMS = ms
                    self.editor?.applyRecognitionHypothesis(text, latencyMS: ms)
                    if result.isFinal { self.restartTaskSoon() }
                }
                if let error, self.isListening {
                    self.status = "인식 재시작: \(error.localizedDescription)"
                    self.restartTaskSoon()
                }
            }
        }
    }

    private func restartTaskSoon() {
        guard isListening, !restarting else { return }
        restarting = true
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard self.isListening else { self.restarting = false; return }
            self.startRecognitionTask()
            self.restarting = false
            self.status = "듣는 중"
        }
    }
}
