import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var editor: EditorStateMachine
    @EnvironmentObject private var speech: WhisperKitBackend
    @EnvironmentObject private var focusedInput: FocusedInputBridge
    @State private var complement = ""
    @State private var showingExporter = false
    @State private var exportDocument = JSONFileDocument(data: Data())

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            globalSettingsBanner
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
                Text("RVE · 전역 음성 입력기").font(.title2.bold())
                Text("WhisperKit 로컬 초저지연 Push-to-Talk (Claude Desktop, Slack, VS Code 등 지원)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("모델", selection: $speech.modelName) {
                Text("tiny (테스트용)").tag("tiny")
                Text("base (기본)").tag("base")
                Text("small (중급)").tag("small")
                Text("medium (상급)").tag("medium")
                Text("large-v3-turbo (✨ 최고성능 한국어)").tag("large-v3-turbo")
            }
            .frame(width: 240)
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

    private var globalSettingsBanner: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.blue)
                Picker("워키토키(PTT) 단축키", selection: $focusedInput.pttKeyMode) {
                    ForEach(PTTKeyMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
            
            Toggle(isOn: $focusedInput.autoSend) {
                HStack(spacing: 4) {
                    Image(systemName: "return")
                        .foregroundStyle(.green)
                    Text("붙여넣기 후 Enter 자동 전송 (Claude / 메신저용)")
                        .font(.callout)
                }
            }
            .toggleStyle(.checkbox)

            Spacer()
            
            Text(focusedInput.status)
                .font(.caption.bold())
                .foregroundStyle(focusedInput.isInstalled ? .green : .orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08))
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
            Button("전역 입력 재설치") { focusedInput.install() }
                .help("선택한 PTT 단축키로 활성화된 앱 입력창에 전역 입력 기능을 재설치합니다.")
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
