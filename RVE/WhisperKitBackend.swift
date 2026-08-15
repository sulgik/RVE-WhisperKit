import Foundation
import AVFoundation
import WhisperKit

@MainActor
final class WhisperKitBackend: ObservableObject, SpeechBackend {
    @Published private(set) var isListening = false
    @Published private(set) var status = "모델 준비 전"
    @Published private(set) var lastLatencyMS: Int?
    @Published var modelName = "openai_whisper-large-v3-turbo"

    var onNaturalStop: (() -> Void)?

    private var whisperKit: WhisperKit?
    private weak var editor: EditorStateMachine?
    private var pollingTask: Task<Void, Never>?
    private var lastProcessedSampleCount = 0
    private var segmentStartedAt = ContinuousClock.now
    private var isTranscribing = false
    private var hasDetectedSpeech = false
    private var lastVoiceAt: ContinuousClock.Instant?
    private var lastTypingAt: ContinuousClock.Instant?

    private let pollInterval = Duration.milliseconds(350)
    private let minimumNewSamples = 8_000
    private let maxWindowSamples = 160_000
    private let silenceLimit = Duration.milliseconds(1_500)
    private let voiceRMSFloor: Float = 0.022
    private let relativeVoiceFloor: Float = 0.3

    func connect(to editor: EditorStateMachine) { self.editor = editor }

    func prepare() async {
        guard whisperKit == nil else { return }
        guard await requestMicrophoneAccess() else {
            status = "마이크 권한이 필요합니다 · 시스템 설정 > 개인정보 보호 및 보안"
            return
        }
        status = "WhisperKit 모델 로딩 중 (\(modelName))…"
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
                hasDetectedSpeech = false
                lastVoiceAt = nil
                lastTypingAt = nil
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

    // MARK: - Dedicated Walkie-Talkie (Push-to-Talk) Methods
    func startPTT() {
        guard !isListening else { return }
        Task {
            if whisperKit == nil { await prepare() }
            guard let whisperKit else { return }

            do {
                try whisperKit.audioProcessor.startRecordingLive(inputDeviceID: nil) { _ in }
                isListening = true
                status = "🎙️ 워키토키 녹음 중…"
            } catch {
                status = "마이크 시작 실패: \(error.localizedDescription)"
            }
        }
    }

    func finishPTTAndTranscribe(completion: @escaping (String) -> Void) {
        guard isListening, let whisperKit else {
            isListening = false
            status = "중지됨"
            completion("")
            return
        }

        whisperKit.audioProcessor.stopRecording()
        isListening = false
        status = "⏳ Whisper AI 변환 중…"

        let samples = whisperKit.audioProcessor.audioSamples
        guard !samples.isEmpty else {
            status = "녹음된 음성이 없습니다"
            completion("")
            return
        }

        Task {
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
                let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
                let text = results.map(\.text).joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let elapsed = started.duration(to: .now)
                let ms = Self.milliseconds(elapsed)
                self.lastLatencyMS = ms
                self.status = text.isEmpty ? "인식 결과 없음" : "완료 (\(ms)ms)"
                completion(text)
            } catch {
                self.status = "인식 오류: \(error.localizedDescription)"
                completion("")
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        whisperKit?.audioProcessor.stopRecording()
        isListening = false
        status = "중지됨"
        hasDetectedSpeech = false
        lastVoiceAt = nil
        lastTypingAt = nil
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
                if self.shouldStopForSilence() {
                    await self.transcribeCurrentWindowIfNeeded(force: true)
                    self.stop()
                    self.status = "무음 감지 · 입력 완료"
                    self.onNaturalStop?()
                    break
                }
                await self.transcribeCurrentWindowIfNeeded()
            }
        }
    }

    private func transcribeCurrentWindowIfNeeded(force: Bool = false) async {
        guard !isTranscribing, let whisperKit else { return }
        let samples = whisperKit.audioProcessor.audioSamples
        let newSampleCount = samples.count - lastProcessedSampleCount
        guard newSampleCount > 0, force || newSampleCount >= minimumNewSamples else { return }

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

            hasDetectedSpeech = true
            if lastVoiceAt == nil { lastVoiceAt = .now }

            let elapsed = started.duration(to: .now)
            let ms = Self.milliseconds(elapsed)
            lastLatencyMS = ms
            lastProcessedSampleCount = samples.count
            editor?.applyRecognitionHypothesis(text, latencyMS: ms)

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

    private func shouldStopForSilence() -> Bool {
        guard let whisperKit else { return false }
        let samples = whisperKit.audioProcessor.audioSamples
        guard !samples.isEmpty else { return false }

        let relativeEnergy = whisperKit.audioProcessor.relativeEnergy
        let windowSize = min(samples.count, 4_000)
        let trailing = samples.suffix(windowSize)
        let meanSquare = trailing.reduce(Float.zero) { $0 + $1 * $1 } / Float(windowSize)
        let absoluteRMS = meanSquare.squareRoot()
        let voiceDetected: Bool
        if relativeEnergy.count >= 3 {
            voiceDetected = absoluteRMS >= 0.01
                && relativeEnergy.suffix(3).contains { $0 >= relativeVoiceFloor }
        } else {
            voiceDetected = absoluteRMS >= voiceRMSFloor
        }

        if voiceDetected {
            hasDetectedSpeech = true
            lastVoiceAt = .now
            return false
        }

        guard hasDetectedSpeech, let lastVoiceAt else { return false }
        let noRecentVoice = lastVoiceAt.duration(to: .now) >= silenceLimit
        let noRecentTyping = lastTypingAt.map { $0.duration(to: .now) >= silenceLimit } ?? true
        return noRecentVoice && noRecentTyping
    }

    func registerTypingActivity() {
        guard isListening else { return }
        lastTypingAt = .now
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
