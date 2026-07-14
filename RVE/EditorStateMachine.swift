import Foundation

@MainActor
final class EditorStateMachine: ObservableObject {
    @Published private(set) var committedText = ""
    @Published private(set) var draftText = ""
    @Published private(set) var lastEvent = "준비"
    @Published private(set) var eventLog: [EditorEvent] = []

    private var undoStack: [Snapshot] = []
    private var segmentSeedCommitted = ""
    private var segmentSeedDraft = ""
    private var voiceCommandUndoRegistered = false
    private var lastHypothesisActionSignature = ""
    private var insertionSessionActive = false

    private let commands: [(phrases: [String], action: CommandAction)] = [
        (["아니 다시", "아니, 다시", "다시 말할게", "다시 말하겠습니다", "처음부터 다시"], .restartDraft),
        (["새 문단", "다음 문단"], .newParagraph),
        (["여기까지", "문장 확정", "확정해"], .commit)
    ]

    init() {
        beginRecognitionSegment()
    }

    func beginRecognitionSegment() {
        segmentSeedCommitted = committedText
        segmentSeedDraft = draftText
        voiceCommandUndoRegistered = false
        lastHypothesisActionSignature = ""
    }

    /// A global-hotkey dictation session always starts with a clean buffer so a
    /// later paste cannot include text from an earlier destination app.
    func beginInsertionSession() {
        committedText = ""
        draftText = ""
        undoStack.removeAll()
        insertionSessionActive = true
        beginRecognitionSegment()
        lastEvent = "INSERTION_SESSION_START"
        log("INSERTION_SESSION_START")
    }

    var insertionSessionText: String {
        guard insertionSessionActive else { return "" }
        return [committedText, draftText]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func finishInsertionSession() {
        insertionSessionActive = false
        committedText = ""
        draftText = ""
        beginRecognitionSegment()
        lastEvent = "INSERTION_SESSION_PASTED"
        log("INSERTION_SESSION_PASTED")
    }

    /// Replays the current ASR hypothesis from the segment seed. This makes partial-result
    /// revisions deterministic and prevents the same spoken command from firing twice.
    func applyRecognitionHypothesis(_ transcript: String, latencyMS: Int?) {
        var workingCommitted = segmentSeedCommitted
        var workingDraft = segmentSeedDraft
        var remaining = transcript.normalizedSpaces
        var actions: [String] = []

        while let match = earliestCommand(in: remaining) {
            let before = String(remaining[..<match.range.lowerBound]).trimmed
            let after = String(remaining[match.range.upperBound...]).trimmed
            workingDraft = join(workingDraft, before)

            switch match.action {
            case .restartDraft:
                workingDraft = ""
                actions.append("ROLLBACK_DRAFT")
            case .commit:
                workingCommitted = appendCommitted(workingCommitted, workingDraft, paragraph: false)
                workingDraft = ""
                actions.append("COMMIT")
            case .newParagraph:
                workingCommitted = appendCommitted(workingCommitted, workingDraft, paragraph: true)
                workingDraft = ""
                actions.append("NEW_PARAGRAPH")
            }
            remaining = after
        }

        workingDraft = join(workingDraft, remaining)
        committedText = workingCommitted
        draftText = workingDraft
        lastEvent = actions.last ?? "실시간 인식"

        log("TRANSCRIPT_UPDATE", detail: transcript, latencyMS: latencyMS)
        if let latencyMS {
            log("LATENCY", detail: "transcription", latencyMS: latencyMS)
        }

        let signature = actions.joined(separator: ",")
        if signature != lastHypothesisActionSignature {
            if !voiceCommandUndoRegistered,
               actions.contains(where: { $0 == "COMMIT" || $0 == "NEW_PARAGRAPH" }) {
                undoStack.append(Snapshot(committed: segmentSeedCommitted, draft: segmentSeedDraft))
                voiceCommandUndoRegistered = true
            }
            for action in actions {
                log(action, detail: transcript, latencyMS: latencyMS)
            }
            lastHypothesisActionSignature = signature
        }
    }

    func commitDraft() {
        guard !draftText.trimmed.isEmpty else { return }
        pushUndo()
        committedText = appendCommitted(committedText, draftText, paragraph: false)
        draftText = ""
        beginRecognitionSegment()
        lastEvent = "ENTER_COMMIT"
        log("ENTER_COMMIT")
    }

    func commitParagraph() {
        guard !draftText.trimmed.isEmpty else { return }
        pushUndo()
        committedText = appendCommitted(committedText, draftText, paragraph: true)
        draftText = ""
        beginRecognitionSegment()
        lastEvent = "PARAGRAPH_COMMIT"
        log("PARAGRAPH_COMMIT")
    }

    func cancelDraft() {
        guard !draftText.isEmpty else { return }
        pushUndo()
        draftText = ""
        beginRecognitionSegment()
        lastEvent = "CANCEL_DRAFT"
        log("CANCEL_DRAFT")
    }

    func insertComplement(_ text: String) {
        let value = text.trimmed
        guard !value.isEmpty else { return }
        pushUndo()
        draftText = join(draftText, value)
        beginRecognitionSegment()
        lastEvent = "COMPLEMENT_INSERT"
        log("COMPLEMENT_INSERT", detail: value)
    }

    func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        committedText = snapshot.committed
        draftText = snapshot.draft
        beginRecognitionSegment()
        lastEvent = "UNDO"
        log("UNDO")
    }

    func clearAll() {
        pushUndo()
        committedText = ""
        draftText = ""
        beginRecognitionSegment()
        lastEvent = "CLEAR_ALL"
        log("CLEAR_ALL")
    }

    func exportLogData() throws -> Data {
        try JSONEncoder.pretty.encode(eventLog)
    }

    private func earliestCommand(in text: String) -> CommandMatch? {
        let lowered = text.lowercased()
        var result: CommandMatch?
        for command in commands {
            for phrase in command.phrases {
                guard let range = lowered.range(of: phrase.lowercased()) else { continue }
                let candidate = CommandMatch(range: range, action: command.action)
                if result == nil || range.lowerBound < result!.range.lowerBound {
                    result = candidate
                }
            }
        }
        return result
    }

    private func join(_ left: String, _ right: String) -> String {
        let l = left.trimmed
        let r = right.trimmed
        if l.isEmpty { return r }
        if r.isEmpty { return l }
        return l + " " + r
    }

    private func appendCommitted(_ committed: String, _ draft: String, paragraph: Bool) -> String {
        let body = draft.trimmed
        guard !body.isEmpty else { return committed }
        let existing = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existing.isEmpty else { return body + (paragraph ? "\n\n" : "") }
        return existing + (paragraph ? "\n\n" : " ") + body + (paragraph ? "\n\n" : "")
    }

    private func pushUndo() {
        undoStack.append(Snapshot(committed: committedText, draft: draftText))
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    private func log(_ type: String, detail: String? = nil, latencyMS: Int? = nil) {
        let event = EditorEvent(timestamp: Date(), type: type, detail: detail, latencyMS: latencyMS)
        if eventLog.last?.type == type && eventLog.last?.detail == detail { return }
        eventLog.append(event)
    }
}

private enum CommandAction { case restartDraft, commit, newParagraph }
private struct CommandMatch { let range: Range<String.Index>; let action: CommandAction }
private struct Snapshot { let committed: String; let draft: String }

struct EditorEvent: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let type: String
    let detail: String?
    let latencyMS: Int?

    init(timestamp: Date, type: String, detail: String? = nil, latencyMS: Int? = nil) {
        self.id = UUID(); self.timestamp = timestamp; self.type = type
        self.detail = detail; self.latencyMS = latencyMS
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedSpaces: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmed
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
