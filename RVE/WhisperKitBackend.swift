import Foundation
import AVFoundation
import WhisperKit

@MainActor
final class WhisperKitBackend: ObservableObject, SpeechBackend {
    @Published private(set) var isListening = false
    @Published private(set) var status = "모델 준비 전"
    @Published private(set) var lastLatencyMS: Int?
    @Published var modelName = "tiny"

    private var whisperKit: WhisperKit?
    private weak var editor: EditorStateMachine?
    private var pollingTask: Task<Void, Never>?
    private var lastProcessedSampleCount = 0
    private var segmentStartedAt = ContinuousClock.now
    private var isTranscribing = false

    /// A short rolling-window implementation chosen for MVP stability.
    /// It produces partial hypotheses every ~700 ms without waiting for Enter.
    private let pollInterval = Duration.milliseconds(700)
    private let minimumNewSamples = 8_000       // ~0.5 sec at 16 kHz
    private let maxWindowSamples = 160_000      // 10 sec at 16 kHz

    func connect(to editor: EditorStateMachine) { self.editor = editor }

    func prepare() async {
        guard whisperKit == nil else { return }
        guard await requestMicrophoneAccess() else {
            status = "마이크 권한이 필요합니다 · 시스템 설정 > 개인정보 보호 및 보안"
            return
        }
        status = "WhisperKit 모델 로딩 중…"
        do {
            let config = WhisperKitConfig(model: modelName)
            whisperKit = try await WhisperKit(config)
            status = "준비됨 · \(modelName)"
        } catch {
            status = "모델 로딩 실패: \(error.localizedDescription)"
        }
    }

    func toggle() { isListening ? stop() : start() }

    func start() {
        guard !isListening else { return }
        Task {
            if whisperKit == nil { await prepare() }
            guard let whisperKit else { return }

            do {
                try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { _ in }
                lastProcessedSampleCount = 0
                segmentStartedAt = .now
                editor?.beginRecognitionSegment()
                isListening = true
                status = "듣는 중 · WhisperKit \(modelName)"
                beginPolling()
            } catch {
                status = "마이크 시작 실패: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        whisperKit?.audioProcessor.stopRecording()
        isListening = false
        status = "중지됨"
    }

    func reloadModel() async {
        stop()
        whisperKit = nil
        await prepare()
    }

    private func beginPolling() {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.pollInterval ?? .milliseconds(700))
                guard let self, self.isListening else { break }
                await self.transcribeCurrentWindowIfNeeded()
            }
        }
    }

    private func transcribeCurrentWindowIfNeeded() async {
        guard !isTranscribing, let whisperKit else { return }
        let samples = whisperKit.audioProcessor.audioSamples
        guard samples.count - lastProcessedSampleCount >= minimumNewSamples else { return }

        isTranscribing = true
        defer { isTranscribing = false }

        let start = max(0, samples.count - maxWindowSamples)
        let window = Array(samples[start..<samples.count])
        let started = ContinuousClock.now

        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "ko",
                temperature: 0,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false
            )
            let results = try await whisperKit.transcribe(audioArray: window, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let elapsed = started.duration(to: .now)
            let ms = Self.milliseconds(elapsed)
            lastLatencyMS = ms
            lastProcessedSampleCount = samples.count
            editor?.applyRecognitionHypothesis(text, latencyMS: ms)

            // Make a completed window the next segment's immutable seed. Keep audio that
            // arrived while decoding so continuous listening never drops fresh samples.
            if samples.count >= maxWindowSamples {
                editor?.beginRecognitionSegment()
                let arrivedDuringDecode = max(0, whisperKit.audioProcessor.audioSamples.count - samples.count)
                whisperKit.audioProcessor.purgeAudioSamples(keepingLast: arrivedDuringDecode)
                lastProcessedSampleCount = 0
            }
        } catch {
            status = "인식 오류: \(error.localizedDescription)"
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let c = duration.components
        return Int(c.seconds) * 1000 + Int(Double(c.attoseconds) / 1e15)
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}
