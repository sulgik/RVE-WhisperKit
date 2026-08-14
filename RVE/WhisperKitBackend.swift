import Foundation
import AVFoundation
import WhisperKit

@MainActor
final class WhisperKitBackend: ObservableObject, SpeechBackend {
    @Published private(set) var isListening = false
    @Published private(set) var status = "모델 준비 전"
    @Published private(set) var lastLatencyMS: Int?
    @Published var modelName = "tiny"

    /// Set by the focused-input bridge. Regular in-app recording still stops on
    /// silence, but only an active bridge session pastes into another app.
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

    /// A short rolling-window implementation chosen for MVP stability.
    /// It produces partial hypotheses every ~700 ms without waiting for Enter.
    // Check silence frequently; `minimumNewSamples` still keeps ASR updates at
    // roughly 700 ms rather than decoding on every timer tick.
    private let pollInterval = Duration.milliseconds(350)
    private let minimumNewSamples = 8_000       // ~0.5 sec at 16 kHz
    private let maxWindowSamples = 160_000      // 10 sec at 16 kHz
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

    func finishAndTranscribeFinal(completion: @escaping () -> Void) {
        pollingTask?.cancel()
        pollingTask = nil
        guard isListening, let whisperKit else {
            stop()
            completion()
            return
        }
        Task {
            await transcribeCurrentWindowIfNeeded(force: true)
            stop()
            completion()
        }
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

            // A decoder can hallucinate short text over silence. It may confirm
            // that this session contained speech, but it must never refresh the
            // physical voice-activity clock used for automatic stopping.
            hasDetectedSpeech = true
            if lastVoiceAt == nil { lastVoiceAt = .now }

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

    /// WhisperKit already maintains energy relative to the quietest recent input.
    /// Prefer that adaptive value so a steady fan or room noise becomes the silence
    /// baseline instead of keeping the session alive forever.
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
            // Relative energy adapts to the room, while the small absolute floor
            // prevents microphone self-noise from repeatedly resetting the timer.
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

    /// Called by the global shortcut monitor. Typing while dictating is treated
    /// as active editing, so a pause in speech cannot paste over a correction.
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
