import AppKit

public struct FeedbackPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }
    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct FeedbackMarkup: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pin, drawing }
    public let kind: Kind
    public let pin: FeedbackPoint?
    public let strokes: [[FeedbackPoint]]
    public let elementName: String
    public let elementRole: String?
}

public struct FeedbackConversationMessage: Codable, Sendable {
    public let role: String
    public let text: String
}

/// Hosts can connect an optional clarification service. The default flow saves directly.
public struct FeedbackQuestion: Sendable {
    public let text: String
    public let suggestions: [String]
    public init(text: String, suggestions: [String] = []) {
        self.text = text
        self.suggestions = suggestions
    }
}

public typealias FeedbackQuestionProvider =
    @Sendable (String, String) async throws -> FeedbackQuestion?

struct FeedbackElement: Equatable {
    let name: String
    let role: String?
    let frame: CGRect
    let source: FeedbackTargetSnapshot?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.frame == rhs.frame && lhs.source?.id == rhs.source?.id
    }
}

@MainActor
final class FeedbackSession: ObservableObject {
    enum Phase: Equatable {
        case annotating, drawing, composing, recording, clarifying, saving, receipt, failed
    }
    @Published private(set) var phase: Phase = .annotating
    @Published var description = ""
    @Published var category: FeedbackCategory?
    @Published var answer = ""
    @Published var includeScreenshot = true
    @Published var selectedElement: FeedbackElement?
    @Published private(set) var strokes: [[FeedbackPoint]] = []
    @Published private(set) var redoStrokes: [[FeedbackPoint]] = []
    @Published private(set) var pin: FeedbackPoint?
    @Published private(set) var capture: CapturedWindow?
    @Published private(set) var context: FeedbackReportContext
    @Published private(set) var question: FeedbackQuestion?
    @Published private(set) var conversation: [FeedbackConversationMessage] = []
    @Published private(set) var error: String?
    @Published private(set) var savedURL: URL?
    @Published var showDetails = false
    @Published var showReplay = false
    @Published private(set) var recording: FeedbackRecording?
    let directory: URL
    private(set) var events: [FeedbackEvent]
    private var captureTask: Task<CapturedWindow, Never>?
    private var workTask: Task<Void, Never>?
    private var recorder: FeedbackWindowRecording?
    private let questionProvider: FeedbackQuestionProvider?
    private let captureProvider: @MainActor (NSWindow) async -> CapturedWindow
    private var closed = false
    private var captureID = UUID()
    var presentationChanged: (() -> Void)?
    var captureStateChanged: ((Bool) -> Void)?
    var close: (() -> Void)?
    weak var sourceWindow: NSWindow?
    var contextProvider: () -> [String: String]

    init(
        window: NSWindow, directory: URL, contextProvider: @escaping () -> [String: String],
        questionProvider: FeedbackQuestionProvider?,
        captureProvider: @escaping @MainActor (NSWindow) async -> CapturedWindow = {
            await FeedbackCapture.capture(window: $0)
        }
    ) {
        sourceWindow = window
        self.directory = directory
        self.contextProvider = contextProvider
        self.questionProvider = questionProvider
        self.captureProvider = captureProvider
        let tree = FeedbackCapture.collectAccessibility(root: window)
        context = FeedbackReportContext(
            capturedAt: Date(),
            environment: [
                "feedback.windowWidth": String(Double(window.frame.width)),
                "feedback.windowHeight": String(Double(window.frame.height)),
            ], application: contextProvider(),
            targets: FeedbackTargetRegistry.shared.snapshot(in: window),
            accessibility: tree.nodes, diagnostics: tree.diagnostics, description: "",
            selection: nil, selectedTarget: nil)
        events = FeedbackRecorder.shared.snapshot()
    }

    func startCapture() {
        guard let window = sourceWindow else { return }
        let id = UUID()
        captureID = id
        captureStateChanged?(true)
        let captureProvider = captureProvider
        let task = Task { await captureProvider(window) }
        captureTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, !self.closed, self.captureID == id, !Task.isCancelled else { return }
            self.capture = result
            self.context = self.mergedContext(result)
            self.captureStateChanged?(false)
        }
    }

    private func mergedContext(_ captured: CapturedWindow) -> FeedbackReportContext {
        var environment = captured.metadata
        environment["feedback.windowWidth"] = context.environment["feedback.windowWidth"]
        environment["feedback.windowHeight"] = context.environment["feedback.windowHeight"]
        let changed = captured.metadata["screenshot.geometryChangedDuringCapture"] == "true"
        return FeedbackReportContext(
            capturedAt: context.capturedAt, environment: environment,
            application: context.application, targets: changed ? [] : context.targets,
            accessibility: captured.accessibility, diagnostics: captured.diagnostics,
            description: "", selection: nil, selectedTarget: nil)
    }

    func element(at point: CGPoint) -> FeedbackElement? {
        let source = FeedbackTargetSnapshot.hitTest(point, in: context.targets)
        let windowFrame = sourceWindow?.frame ?? .zero
        let candidates = context.accessibility.compactMap { node -> FeedbackElement? in
            guard let raw = node.frame?.cgRect, raw.width > 1, raw.height > 1,
                !["AXWindow", "AXGroup", "AXScrollArea", "AXList", "unknown"].contains(node.role)
            else { return nil }
            let frame = CGRect(
                x: raw.minX - windowFrame.minX, y: windowFrame.maxY - raw.maxY,
                width: raw.width, height: raw.height)
            guard frame.contains(point),
                frame.width * frame.height < windowFrame.width * windowFrame.height * 0.8
            else { return nil }
            return FeedbackElement(
                name: node.label ?? node.value ?? node.identifier ?? node.role,
                role: node.role, frame: frame, source: source)
        }
        let smallest = candidates.min {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
        if let source,
            smallest == nil
                || source.frame.width * source.frame.height <= smallest!.frame.width
                    * smallest!.frame.height
        {
            return FeedbackElement(
                name: source.label, role: nil, frame: source.frame.cgRect, source: source)
        }
        return smallest
            ?? source.map {
                FeedbackElement(name: $0.label, role: nil, frame: $0.frame.cgRect, source: $0)
            }
    }

    func windowResized() {
        guard phase != .recording && phase != .saving && phase != .receipt && phase != .failed
        else { return }
        let frame = sourceWindow?.frame ?? .zero
        let oldWidth = Double(context.environment["feedback.windowWidth"] ?? "") ?? 0
        let oldHeight = Double(context.environment["feedback.windowHeight"] ?? "") ?? 0
        guard abs(frame.width - oldWidth) > 1 || abs(frame.height - oldHeight) > 1 else { return }
        workTask?.cancel()
        captureID = UUID()
        captureTask?.cancel()
        captureTask = nil
        capture = nil
        captureStateChanged?(false)
        strokes.removeAll()
        redoStrokes.removeAll()
        pin = nil
        selectedElement = nil
        question = nil
        conversation.removeAll()
        refreshScene()
        setPhase(.annotating)
    }

    func refreshScene() {
        guard let window = sourceWindow else { return }
        let tree = FeedbackCapture.collectAccessibility(root: window)
        context = FeedbackReportContext(
            capturedAt: Date(),
            environment: [
                "feedback.windowWidth": String(Double(window.frame.width)),
                "feedback.windowHeight": String(Double(window.frame.height)),
            ], application: contextProvider(),
            targets: FeedbackTargetRegistry.shared.snapshot(in: window),
            accessibility: tree.nodes, diagnostics: tree.diagnostics, description: "",
            selection: nil, selectedTarget: nil)
    }

    func select(at point: CGPoint) {
        guard phase == .annotating else { return }
        refreshScene()
        selectedElement = element(at: point)
        startCapture()
        pin = FeedbackPoint(point)
        includeScreenshot = true
        setPhase(.composing)
    }

    func select(_ target: FeedbackTargetSnapshot) {
        guard phase == .annotating else { return }
        refreshScene()
        startCapture()
        selectedElement = FeedbackElement(
            name: target.label, role: nil, frame: target.frame.cgRect, source: target)
        pin = FeedbackPoint(
            CGPoint(
                x: target.frame.x + target.frame.width / 2,
                y: target.frame.y + target.frame.height / 2))
        setPhase(.composing)
    }

    func addStroke(_ points: [CGPoint]) {
        guard phase == .annotating || phase == .drawing, points.count > 1 else { return }
        if strokes.isEmpty {
            refreshScene()
            startCapture()
        }
        strokes.append(points.map(FeedbackPoint.init))
        redoStrokes.removeAll()
        pin = nil
        includeScreenshot = true
        if let point = points.first { selectedElement = element(at: point) }
        setPhase(.drawing)
    }

    func undo() {
        guard phase == .drawing, let stroke = strokes.popLast() else { return }
        redoStrokes.append(stroke)
    }
    func redo() {
        guard phase == .drawing, let stroke = redoStrokes.popLast() else { return }
        strokes.append(stroke)
    }

    func markupMode() {
        guard phase != .saving && phase != .receipt && phase != .clarifying else { return }
        recorder?.cancel()
        recorder = nil
        recording = nil
        captureID = UUID()
        captureTask?.cancel()
        captureTask = nil
        capture = nil
        captureStateChanged?(false)
        strokes.removeAll()
        redoStrokes.removeAll()
        pin = nil
        selectedElement = nil
        description = ""
        category = nil
        answer = ""
        error = nil
        conversation.removeAll()
        showReplay = false
        setPhase(.annotating)
    }

    func toggleCategory(_ value: FeedbackCategory) {
        category = category == value ? nil : value
    }

    func restartMarkup() {
        let draft = description
        let draftCategory = category
        markupMode()
        description = draft
        category = draftCategory
        refreshScene()
    }

    func escape() {
        switch phase {
        case .drawing: markupMode()
        case .recording: stopRecording()
        case .saving: break
        default: close?()
        }
    }

    func beginRecording() {
        guard phase == .annotating || phase == .drawing || phase == .composing,
            let window = sourceWindow
        else { return }
        markupMode()
        let recorder = FeedbackWindowRecording(window: window, contextProvider: contextProvider)
        self.recorder = recorder
        recorder.onFinish = { [weak self] result in
            guard let self, !self.closed, self.phase == .recording else { return }
            self.recording = result
            self.events = result.events
            let tree = FeedbackCapture.collectAccessibility(root: window)
            self.context = FeedbackReportContext(
                capturedAt: Date(),
                environment: [
                    "feedback.windowWidth": String(Double(window.frame.width)),
                    "feedback.windowHeight": String(Double(window.frame.height)),
                ], application: self.contextProvider(),
                targets: FeedbackTargetRegistry.shared.snapshot(in: window),
                accessibility: tree.nodes, diagnostics: tree.diagnostics, description: "",
                selection: nil, selectedTarget: nil)
            self.capture = nil
            self.startCapture()
            self.setPhase(.composing)
        }
        setPhase(.recording)
        recorder.start()
    }
    func stopRecording() { recorder?.finish() }
    var recordingStartedAt: Date? { recorder?.startedAt }

    func submit(_ text: String? = nil) {
        guard phase == .composing || phase == .drawing else { return }
        if let text { description = text }
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !strokes.isEmpty else { return }
        if trimmed.isEmpty { description = "圈画区域需要改进" }
        conversation = [FeedbackConversationMessage(role: "user", text: description)]
        error = nil
        setPhase(.clarifying)
        if let questionProvider {
            workTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let next = try await questionProvider(
                        self.description, self.selectedElement?.name ?? "当前界面")
                    guard !Task.isCancelled, !self.closed else { return }
                    if let next { self.question = next } else { self.save() }
                } catch {
                    guard !Task.isCancelled, !self.closed else { return }
                    self.error = "补充问题暂时不可用，可以直接保存反馈。"
                }
            }
        } else {
            save()
        }
    }

    func finishAnswer(_ text: String? = nil) {
        guard phase == .clarifying else { return }
        let value = (text ?? answer).trimmingCharacters(in: .whitespacesAndNewlines)
        if let question {
            conversation.append(FeedbackConversationMessage(role: "assistant", text: question.text))
        }
        if !value.isEmpty {
            conversation.append(FeedbackConversationMessage(role: "user", text: value))
        }
        save()
    }

    func save() {
        guard phase == .clarifying || phase == .failed else { return }
        workTask?.cancel()
        error = nil
        setPhase(.saving)
        let captureTask = captureTask
        workTask = Task { [weak self] in
            guard let self else { return }
            let result = await captureTask?.value
            guard !Task.isCancelled, !self.closed else { return }
            if let result {
                self.capture = result
                self.context = self.mergedContext(result)
                if result.metadata["screenshot.geometryChangedDuringCapture"] == "true" {
                    self.error = "窗口在采集过程中发生变化，请重新标注；问题说明仍然保留。"
                    self.setPhase(.failed)
                    return
                }
            }
            let markup = FeedbackMarkup(
                kind: self.strokes.isEmpty ? .pin : .drawing, pin: self.pin,
                strokes: self.strokes,
                elementName: self.selectedElement?.name
                    ?? (self.recording == nil ? "圈画区域" : "操作录制"),
                elementRole: self.selectedElement?.role)
            let selection: FeedbackRect? = self.selectedElement.map { FeedbackRect($0.frame) }
            let report = FeedbackReportContext(
                capturedAt: self.context.capturedAt,
                environment: self.context.environment, application: self.context.application,
                targets: self.context.targets,
                accessibility: self.context.accessibility, diagnostics: self.context.diagnostics,
                description: self.description, selection: selection,
                selectedTarget: self.selectedElement?.source,
                markup: self.recording == nil ? markup : nil, conversation: self.conversation,
                category: self.category)
            let events = self.events
            let directory = self.directory
            let recording = self.recording
            let image = self.includeScreenshot || !self.strokes.isEmpty ? self.capture?.image : nil
            let logs = self.capture?.logs ?? []
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try FeedbackReportWriter.write(
                        directory: directory, context: report, events: events,
                        image: image, logs: logs, recording: recording)
                }.value
                guard !self.closed else { return }
                self.savedURL = url
                self.setPhase(.receipt)
            } catch {
                guard !self.closed else { return }
                self.error = error.localizedDescription
                self.setPhase(.failed)
            }
        }
    }

    func cancel() {
        closed = true
        workTask?.cancel()
        captureTask?.cancel()
        recorder?.cancel()
        recorder = nil
        captureStateChanged?(false)
        captureStateChanged = nil
        presentationChanged = nil
        close = nil
    }
    private func setPhase(_ value: Phase) {
        phase = value
        presentationChanged?()
    }
}
