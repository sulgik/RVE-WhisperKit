import Foundation

@MainActor
protocol SpeechBackend: AnyObject, ObservableObject {
    var isListening: Bool { get }
    var status: String { get }
    var lastLatencyMS: Int? { get }
    var modelName: String { get set }
    func connect(to editor: EditorStateMachine)
    func prepare() async
    func toggle()
    func start()
    func stop()
}
