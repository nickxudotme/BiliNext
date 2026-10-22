import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct FeedbackRecording: Sendable {
    struct Frame: Sendable {
        let offset: Double
        let jpeg: Data
    }
    let startedAt: Date
    let duration: Double
    let frames: [Frame]
    let diagnostics: [String]
    var events: [FeedbackEvent] = []
}

/// Native equivalent of interaction replay: bounded window stills plus real input breadcrumbs.
/// It does not claim to be rrweb DOM replay, screen video, or audio.
@MainActor
final class FeedbackWindowRecording {
    private weak var window: NSWindow?
    private var task: Task<Void, Never>?
    private var limitTask: Task<Void, Never>?
    private var frames: [FeedbackRecording.Frame] = []
    private var diagnostics: [String] = []
    private var byteCount = 0
    private var finished = false
    private var timeline: [FeedbackEvent] = []
    private var eventKeys: Set<String> = []
    private var previousState: [String: String] = [:]
    private let contextProvider: () -> [String: String]
    private(set) var startedAt = Date()
    var onFinish: ((FeedbackRecording) -> Void)?
    init(window: NSWindow, contextProvider: @escaping () -> [String: String] = { [:] }) {
        self.window = window
        self.contextProvider = contextProvider
    }

    func start() {
        startedAt = Date()
        let startedAt = startedAt
        appendEvent(
            FeedbackEvent(
                timestamp: startedAt, name: "recording.started",
                fields: ["format": "window-frame-sequence-v1"]))
        sampleEventsAndState()
        limitTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.finish()
        }
        task = Task { [weak self] in
            guard let self, let window = self.window else { return }
            var failures = 0
            while !Task.isCancelled && !self.finished {
                let began = Date()
                self.sampleEventsAndState()
                do {
                    let content = try await SCShareableContent.currentProcess
                    guard
                        let source = content.windows.first(where: {
                            Int($0.windowID) == window.windowNumber
                                && ($0.owningApplication?.processID
                                    ?? ProcessInfo.processInfo.processIdentifier)
                                    == ProcessInfo.processInfo.processIdentifier
                        })
                    else { throw CocoaError(.fileNoSuchFile) }
                    let filter = SCContentFilter(desktopIndependentWindow: source)
                    let size = filter.contentRect.size
                    guard FeedbackCapture.compatibleCaptureSize(size, window.frame.size) else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    let scale = min(1, 1280 / max(size.width, size.height))
                    let config = SCStreamConfiguration()
                    config.width = max(1, Int(size.width * scale))
                    config.height = max(1, Int(size.height * scale))
                    config.showsCursor = false
                    config.capturesAudio = false
                    config.ignoreShadowsSingleWindow = true
                    config.ignoreGlobalClipSingleWindow = true
                    config.includeChildWindows = false
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: filter, configuration: config)
                    let capturedAt = Date()
                    let jpeg = await Task.detached(priority: .utility) { Self.compress(image) }
                        .value
                    guard !Task.isCancelled && !self.finished else { return }
                    if let jpeg, self.byteCount + jpeg.count <= 12_000_000 {
                        self.byteCount += jpeg.count
                        self.frames.append(
                            .init(offset: capturedAt.timeIntervalSince(startedAt), jpeg: jpeg))
                    } else {
                        self.diagnostics.append(
                            "Window-frame recording reached its 12 MB attachment budget.")
                        self.finish()
                        return
                    }
                    failures = 0
                } catch {
                    guard !Task.isCancelled && !self.finished else { return }
                    failures += 1
                    self.diagnostics.append(
                        "Frame unavailable: \((error as NSError).domain) \((error as NSError).code)"
                    )
                    if failures >= 3 {
                        self.finish()
                        return
                    }
                }
                let remaining = max(0.05, 1 - Date().timeIntervalSince(began))
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        task?.cancel()
        limitTask?.cancel()
        sampleEventsAndState()
        appendEvent(
            FeedbackEvent(
                timestamp: Date(), name: "recording.stopped",
                fields: ["frameCount": String(frames.count)]))
        onFinish?(
            FeedbackRecording(
                startedAt: startedAt, duration: min(60, Date().timeIntervalSince(startedAt)),
                frames: frames, diagnostics: diagnostics,
                events: timeline.sorted { $0.timestamp < $1.timestamp }))
        onFinish = nil
    }
    func cancel() {
        finished = true
        task?.cancel()
        limitTask?.cancel()
        onFinish = nil
    }

    private func sampleEventsAndState() {
        for event in FeedbackRecorder.shared.snapshot() where event.timestamp >= startedAt {
            appendEvent(event)
        }
        let state = contextProvider()
        let changed = Self.changedState(from: previousState, to: state)
        if !changed.isEmpty {
            appendEvent(FeedbackEvent(timestamp: Date(), name: "recording.state", fields: changed))
        }
        previousState = state
    }

    static func changedState(from previous: [String: String], to current: [String: String])
        -> [String: String]
    {
        var changed = current.filter { previous[$0.key] != $0.value }.mapValues {
            String($0.prefix(1000))
        }
        for key in previous.keys where current[key] == nil { changed[key] = "[removed]" }
        return changed
    }

    private func appendEvent(_ event: FeedbackEvent) {
        let key =
            String(event.timestamp.timeIntervalSince1970) + event.name
            + event.fields.keys.sorted().map { $0 + "=" + (event.fields[$0] ?? "") }.joined(
                separator: "&")
        guard eventKeys.insert(key).inserted else { return }
        timeline.append(event)
        if timeline.count > 2000 {
            timeline.removeFirst()
            if !diagnostics.contains(
                "Interaction timeline exceeded 2000 entries; older events were discarded.")
            {
                diagnostics.append(
                    "Interaction timeline exceeded 2000 entries; older events were discarded.")
            }
        }
    }

    private nonisolated static func compress(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
