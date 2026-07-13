import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var editor: EditorStateMachine
    @EnvironmentObject private var speech: WhisperKitBackend
    @State private var complement = ""
    @State private var showingExporter = false
    @State private var exportDocument = JSONFileDocument(data: Data())

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editorPane
            Divider()
            controlBar
        }
        .fileExporter(isPresented: $showingExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: "rve-events") { _ in }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("RVE").font(.title2.bold())
                Text("Realtime Voice Editor · WhisperKit 로컬 스트리밍 MVP")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("모델", selection: $speech.modelName) {
                Text("tiny · 빠른 테스트").tag("tiny")
                Text("base · 한국어 권장").tag("base")
                Text("small · 정확도 우선").tag("small")
            }
            .frame(width: 190)
            .disabled(speech.isListening)
            Button("모델 적용") { Task { await speech.reloadModel() } }
                .disabled(speech.isListening)
            statusBadge
            Button(speech.isListening ? "중지" : "말하기 시작") { speech.toggle() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .padding(16)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 8, height: 8)
                .foregroundStyle(speech.isListening ? .green : .secondary)
            Text(speech.status)
            if let ms = speech.lastLatencyMS { Text("\(ms) ms").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    private var editorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                sectionLabel("확정 문서")
                Text(editor.committedText.isEmpty ? "확정된 문장이 여기에 쌓입니다." : editor.committedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(size: 19))
                    .foregroundStyle(editor.committedText.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)

                Divider()
                sectionLabel("현재 Draft")
                Text(editor.draftText.isEmpty ? "말하면 partial transcript가 즉시 나타납니다." : editor.draftText)
                    .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(editor.draftText.isEmpty ? Color.secondary.opacity(0.5) : Color.orange)
                    .textSelection(.enabled)

                HStack {
                    TextField("고유명사·숫자 등 보완 입력", text: $complement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { insertComplement() }
                    Button("Draft에 삽입") { insertComplement() }
                        .disabled(complement.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Button("확정 ↩") { editor.commitDraft() }
            Button("새 문단 ⇧↩") { editor.commitParagraph() }
            Button("Draft 취소 Esc") { editor.cancelDraft() }
            Button("실행 취소 ⌘Z") { editor.undo() }
            Spacer()
            Text("마지막: \(editor.lastEvent)").font(.caption).foregroundStyle(.secondary)
            Button("복사") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(editor.committedText + (editor.draftText.isEmpty ? "" : " " + editor.draftText), forType: .string)
            }
            Button("로그 저장") { exportLog() }
            Button("전체 지우기", role: .destructive) { editor.clearAll() }
        }
        .padding(14)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
    }

    private func insertComplement() {
        editor.insertComplement(complement)
        complement = ""
    }

    private func exportLog() {
        guard let data = try? editor.exportLogData() else { return }
        exportDocument = JSONFileDocument(data: data)
        showingExporter = true
    }
}
