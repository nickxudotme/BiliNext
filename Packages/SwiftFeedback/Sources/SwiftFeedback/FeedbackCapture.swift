import AppKit
import OSLog
import ObjectiveC
import ScreenCaptureKit

@MainActor
public enum FeedbackCapture {
    /// Captures only this process's requested window. Failure never discards the other context.
    public static func capture(window: NSWindow) async -> CapturedWindow {
        let startedAt = Date()
        let logTask = Task.detached(priority: .utility) { captureRecentLogs() }
        let originalFrame = window.frame
        let originalWindowID = CGWindowID(exactly: window.windowNumber)
        var metadata = environmentMetadata(window: window)
        var diagnostics: [String] = []
        let tree = collectAccessibility(root: window)
        metadata.merge(tree.metadata, uniquingKeysWith: { _, latest in latest })
        diagnostics.append(contentsOf: tree.diagnostics)
        var image: CGImage?

        do {
            var source: SCWindow?
            var retryReasons: [String] = []
            for attempt in 1...3 {
                metadata["screenshot.discoveryAttempts"] = String(attempt)
                let content = try await SCShareableContent.currentProcess
                if let originalWindowID,
                    let candidate = content.windows.first(where: { $0.windowID == originalWindowID }
                    )
                {
                    let ownerPID = candidate.owningApplication?.processID
                    metadata["screenshot.matchedWindowID"] = String(candidate.windowID)
                    metadata["screenshot.matchedOwnerPID"] = ownerPID.map(String.init) ?? "redacted"
                    metadata["screenshot.discoveredWindowFrame"] = rectString(candidate.frame)
                    metadata["screenshot.expectedWindowFrame"] = rectString(window.frame)
                    if let details = CGWindowListCopyWindowInfo(
                        .optionIncludingWindow, originalWindowID) as? [[String: Any]],
                        let details = details.first
                    {
                        if let bounds = details[kCGWindowBounds as String] as? [String: Any],
                            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
                        {
                            metadata["screenshot.windowServerFrame"] = rectString(frame)
                        }
                        if let pid = details[kCGWindowOwnerPID as String] as? NSNumber {
                            metadata["screenshot.windowServerOwnerPID"] = pid.stringValue
                        }
                    }
                    if let ownerPID, ownerPID != ProcessInfo.processInfo.processIdentifier {
                        retryReasons.append(
                            "attempt \(attempt): matching window ID had a different owner process")
                    } else if !compatibleCaptureSize(candidate.frame.size, window.frame.size) {
                        retryReasons.append(
                            "attempt \(attempt): ScreenCaptureKit size \(candidate.frame.size) disagreed with NSWindow size \(window.frame.size)"
                        )
                    } else {
                        source = candidate
                        break
                    }
                } else {
                    retryReasons.append(
                        "attempt \(attempt): requested window ID missing from current-process shareable content"
                    )
                }
                if attempt < 3 { try await Task.sleep(for: .milliseconds(150)) }
            }
            metadata["screenshot.discoveryRetries"] = retryReasons.joined(separator: "; ")
            guard let source else {
                metadata["screenshot.status"] = "unavailable"
                diagnostics.append(
                    "Screenshot unavailable: no current-process window with matching identity and geometry after three discoveries. \(retryReasons.joined(separator: "; "))"
                )
                return await finishCapture(
                    image: nil, metadata: metadata, accessibility: tree.nodes,
                    diagnostics: diagnostics, logs: logTask, startedAt: startedAt)
            }

            let filter = SCContentFilter(desktopIndependentWindow: source)
            let requestedScale = max(1, CGFloat(filter.pointPixelScale))
            let size = filter.contentRect.size
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                metadata["screenshot.status"] = "failed"
                diagnostics.append(
                    "Screenshot failed: ScreenCaptureKit returned an invalid window content rectangle."
                )
                return await finishCapture(
                    image: nil, metadata: metadata, accessibility: tree.nodes,
                    diagnostics: diagnostics, logs: logTask, startedAt: startedAt)
            }
            // Bound allocation for unusually large virtual displays without changing the aspect ratio.
            let scale = min(
                requestedScale, 8_192 / max(size.width, size.height),
                sqrt(24_000_000 / (size.width * size.height)))
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int((size.width * scale).rounded()))
            configuration.height = max(1, Int((size.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            configuration.includeChildWindows = false
            configuration.shouldBeOpaque = false

            metadata["screenshot.method"] =
                "ScreenCaptureKit.currentProcess / desktopIndependentWindow"
            metadata["screenshot.contentRect"] = rectString(filter.contentRect)
            metadata["screenshot.widthPoints"] = String(Double(size.width))
            metadata["screenshot.heightPoints"] = String(Double(size.height))
            metadata["screenshot.sourceWindowFrame"] = rectString(source.frame)
            metadata["screenshot.pointPixelScale"] = String(describing: filter.pointPixelScale)
            metadata["screenshot.requestedPixelSize"] =
                "\(configuration.width)x\(configuration.height)"
            metadata["screenshot.coordinateSpace"] =
                "Full window, no shadow; image origin is top left. AX and AppKit frames are global bottom-left screen points."
            metadata["screenshot.childWindows"] = "excluded"
            metadata["screenshot.dynamicRange"] = "SDR"
            metadata["screenshot.downscaled"] = String(scale < requestedScale)
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)
            metadata["screenshot.status"] = "success"
            if let image {
                metadata["screenshot.pixelSize"] = "\(image.width)x\(image.height)"
                metadata["screenshot.colorSpace"] = image.colorSpace?.name as String? ?? "unknown"
                metadata["screenshot.bitsPerComponent"] = String(image.bitsPerComponent)
            }
            if window.frame != originalFrame {
                diagnostics.append(
                    "The window moved or resized during capture; source target geometry may differ from the screenshot."
                )
                metadata["screenshot.geometryChangedDuringCapture"] = "true"
            }
        } catch {
            metadata["screenshot.status"] = "failed"
            let captureError = error as NSError
            diagnostics.append(
                "Screenshot failed (\(captureError.domain) \(captureError.code)): \(captureError.localizedDescription)"
            )
        }
        return await finishCapture(
            image: image, metadata: metadata, accessibility: tree.nodes, diagnostics: diagnostics,
            logs: logTask, startedAt: startedAt)
    }

    static func compatibleCaptureSize(_ source: CGSize, _ window: CGSize) -> Bool {
        source.width.isFinite && source.height.isFinite && source.width > 0 && source.height > 0
            && abs(source.width - window.width) <= 2 && abs(source.height - window.height) <= 2
    }

    private static func finishCapture(
        image: CGImage?, metadata: [String: String], accessibility: [AccessibilityNode],
        diagnostics: [String],
        logs: Task<LogCapture, Never>, startedAt: Date
    ) async -> CapturedWindow {
        let logCapture = await logs.value
        var result = metadata
        result.merge(logCapture.metadata, uniquingKeysWith: { _, latest in latest })
        result["capture.durationMilliseconds"] = String(
            Int(Date().timeIntervalSince(startedAt) * 1_000))
        result["capture.consistency"] =
            "Best effort: metadata and AX are sampled before the asynchronous screenshot; live content can advance."
        return CapturedWindow(
            image: image, metadata: result, accessibility: accessibility,
            diagnostics: diagnostics + logCapture.diagnostics, logs: logCapture.entries)
    }

    private struct LogCapture: Sendable {
        let entries: [FeedbackLogEntry]
        let metadata: [String: String]
        let diagnostics: [String]
    }

    /// OSLogStore can block on system services, so this work must stay off the main actor.
    private nonisolated static func captureRecentLogs() -> LogCapture {
        let started = ProcessInfo.processInfo.systemUptime
        var entries: [FeedbackLogEntry] = []
        var metadata = [
            "logs.method": "OSLogStore.currentProcessIdentifier",
            "logs.requestedWindowSeconds": "120",
            "logs.limit": "200 entries; 10000 scanned entries; 1 second enumeration budget",
            "logs.completeness":
                "Best effort: recent buffered logs may not yet be visible. OSLog private values stay redacted. Credential-bearing messages and URL query strings are removed.",
        ]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let cutoff = Date().addingTimeInterval(-120)
            let position = store.position(date: cutoff)
            let sequence = try store.getEntries(at: position)
            let enumerationStarted = ProcessInfo.processInfo.systemUptime
            var scanned = 0
            var matched = 0
            var scanTruncated = false
            for entry in sequence {
                scanned += 1
                if scanned > 10_000 || ProcessInfo.processInfo.systemUptime - enumerationStarted > 1
                {
                    scanTruncated = true
                    break
                }
                guard let log = entry as? OSLogEntryLog,
                    log.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                    log.date >= cutoff
                else { continue }
                matched += 1
                entries.append(
                    FeedbackLogEntry(
                        timestamp: log.date, level: String(describing: log.level),
                        subsystem: log.subsystem, category: log.category,
                        message: sanitizedLogMessage(log.composedMessage)))
                if entries.count > 200 { entries.removeFirst() }
            }
            metadata["logs.status"] = scanTruncated || matched > 200 ? "partial" : "success"
            metadata["logs.entryCount"] = String(entries.count)
            metadata["logs.scannedCount"] = String(scanned)
            metadata["logs.discardedOlderCount"] = String(max(0, matched - entries.count))
            metadata["logs.scanTruncated"] = String(scanTruncated)
            metadata["logs.durationMilliseconds"] = String(
                Int((ProcessInfo.processInfo.systemUptime - started) * 1_000))
            return LogCapture(
                entries: entries, metadata: metadata,
                diagnostics: scanTruncated
                    ? ["Recent log enumeration reached its budget; newer entries may be missing."]
                    : [])
        } catch {
            let failure = error as NSError
            metadata["logs.status"] = "failed"
            metadata["logs.entryCount"] = "0"
            return LogCapture(
                entries: [], metadata: metadata,
                diagnostics: [
                    "Current-process logs unavailable (\(failure.domain) \(failure.code)): \(failure.localizedDescription)"
                ])
        }
    }

    nonisolated static func sanitizedLogMessage(_ message: String) -> String {
        // Remove the entire entry when it contains a credential field. This avoids guessing its delimiter.
        let credentialPattern =
            #"(?i)\b(authorization|proxy-authorization|set-cookie|cookie|sessdata|bili_jct|access[_-]?token|refresh[_-]?token|token|api[_-]?key|password|passwd|secret)\b[\"']?\s*[:=]"#
        if message.range(of: credentialPattern, options: .regularExpression) != nil {
            return "[redacted: credential-bearing log entry]"
        }
        let input = String(message.prefix(4_096))
        guard
            let expression = try? NSRegularExpression(
                pattern: #"https?://[^\s<>\"']+"#, options: .caseInsensitive)
        else { return input }
        var sanitized = input
        let matches = expression.matches(in: input, range: NSRange(input.startIndex..., in: input))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: sanitized) else { continue }
            let original = String(sanitized[range])
            guard var components = URLComponents(string: original) else {
                sanitized.replaceSubrange(range, with: "[redacted URL]")
                continue
            }
            let hadSensitiveParts =
                components.query != nil || components.fragment != nil || components.user != nil
                || components.password != nil
            components.query = nil
            components.fragment = nil
            components.user = nil
            components.password = nil
            sanitized.replaceSubrange(
                range,
                with: (components.string ?? "[redacted URL]")
                    + (hadSensitiveParts ? " [URL parameters removed]" : ""))
        }
        return sanitized + (message.count > 4_096 ? "… [truncated]" : "")
    }

    private static func environmentMetadata(window: NSWindow) -> [String: String] {
        let process = ProcessInfo.processInfo
        let bundle = Bundle.main
        var result: [String: String] = [
            "environment.status": "success",
            "environment.operatingSystem": process.operatingSystemVersionString,
            "environment.processArchitecture": architecture,
            "environment.cpuCount": String(process.processorCount),
            "environment.activeCPUCount": String(process.activeProcessorCount),
            "environment.physicalMemoryBytes": String(process.physicalMemory),
            "environment.systemUptimeSeconds": String(Int(process.systemUptime)),
            "environment.thermalState": String(describing: process.thermalState),
            "environment.lowPowerMode": String(process.isLowPowerModeEnabled),
            "environment.locale": Locale.current.identifier,
            "environment.timeZone": TimeZone.current.identifier,
            "environment.preferredLanguages": Locale.preferredLanguages.joined(separator: ", "),
            "application.status": "success",
            "app.name": bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? process.processName,
            "application.bundleIdentifier": bundle.bundleIdentifier ?? "unknown",
            "application.version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "unknown",
            "application.build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            "application.processIdentifier": String(process.processIdentifier),
            "application.active": String(NSApp?.isActive ?? false),
            "application.windowCount": String(NSApp?.windows.count ?? 0),
            "window.status": "success",
            "window.number": String(window.windowNumber),
            "window.title": String(window.title.prefix(512)),
            "window.frame": rectString(window.frame),
            "window.contentLayoutRect": rectString(window.contentLayoutRect),
            "window.backingScaleFactor": String(describing: window.backingScaleFactor),
            "window.key": String(window.isKeyWindow),
            "window.main": String(window.isMainWindow),
            "window.visible": String(window.isVisible),
            "window.miniaturized": String(window.isMiniaturized),
            "window.occluded": String(!window.occlusionState.contains(.visible)),
            "window.styleMask": String(window.styleMask.rawValue),
            "window.fullScreen": String(window.styleMask.contains(.fullScreen)),
            "window.level": String(window.level.rawValue),
            "window.appearance": window.effectiveAppearance.name.rawValue,
            "window.attachedSheet": String(window.attachedSheet != nil),
            "window.firstResponderType": window.firstResponder.map {
                String(reflecting: type(of: $0))
            } ?? "none",
            "window.firstResponderChain": responderChain(from: window.firstResponder).joined(
                separator: " → "),
            "capture.sampledAt": ISO8601DateFormatter().string(from: Date()),
            "capture.exclusions":
                "No clipboard, browser storage, arbitrary defaults, request bodies, or editable AX text values are read. Known credential fields in logs are redacted. Screenshots, static UI text, and unrecognized log text can contain personal information.",
        ]
        if let screen = window.screen {
            result["screen.status"] = "success"
            result["screen.name"] = screen.localizedName
            result["screen.frame"] = rectString(screen.frame)
            result["screen.visibleFrame"] = rectString(screen.visibleFrame)
            result["screen.scale"] = String(describing: screen.backingScaleFactor)
            result["screen.colorSpace"] = screen.colorSpace?.localizedName ?? "unknown"
            result["screen.maximumFramesPerSecond"] = String(screen.maximumFramesPerSecond)
            result["screen.maximumExtendedDynamicRange"] = String(
                describing: screen.maximumExtendedDynamicRangeColorComponentValue)
        } else {
            result["screen.status"] = "unavailable"
        }
        return result
    }

    private static var architecture: String {
        #if arch(arm64)
            return "arm64"
        #elseif arch(x86_64)
            return "x86_64"
        #else
            return "unknown"
        #endif
    }

    private static func responderChain(from firstResponder: NSResponder?) -> [String] {
        var result: [String] = []
        var current = firstResponder
        var visited: Set<ObjectIdentifier> = []
        while let responder = current, result.count < 16,
            visited.insert(ObjectIdentifier(responder)).inserted
        {
            result.append(String(reflecting: type(of: responder)))
            current = responder.nextResponder
        }
        return result
    }

    private static func rectString(_ rect: CGRect) -> String {
        "x=\(rect.origin.x), y=\(rect.origin.y), width=\(rect.width), height=\(rect.height)"
    }

    struct AccessibilityCapture {
        let nodes: [AccessibilityNode]
        let metadata: [String: String]
        let diagnostics: [String]
    }

    /// AppKit and SwiftUI can expose proxy objects using the public informal accessibility
    /// protocol without declaring NSAccessibilityProtocol conformance. Keep that compatibility
    /// boundary here: check selectors, read only advertised attributes, and never send actions.
    private struct AccessibilityReader {
        private let modern: (any NSAccessibilityProtocol)?
        private let legacy: NSObject?
        private let attributes: Set<String>
        let accessMethod: String
        private static let namesSelector = NSSelectorFromString("accessibilityAttributeNames")
        private static let valueSelector = NSSelectorFromString("accessibilityAttributeValue:")

        init?(_ object: AnyObject) {
            if let modern = object as? any NSAccessibilityProtocol {
                self.modern = modern
                legacy = nil
                attributes = []
                accessMethod = "NSAccessibilityProtocol"
                return
            }
            guard let legacy = object as? NSObject else { return nil }
            let names: [String]
            if legacy.responds(to: Self.namesSelector), legacy.responds(to: Self.valueSelector) {
                names = legacy.perform(Self.namesSelector)?.takeUnretainedValue() as? [String] ?? []
            } else {
                names = []
            }
            // SwiftUI.AccessibilityNode implements getters without full protocol conformance;
            // its inherited informal getters can return nil for every advertised attribute.
            let hasObjectGetters = [
                "accessibilityRole", "accessibilityLabel", "accessibilityChildren",
            ]
            .contains { Self.supportsObjectGetter(legacy, name: $0) }
            guard !names.isEmpty || hasObjectGetters else { return nil }
            modern = nil
            self.legacy = legacy
            attributes = Set(names)
            accessMethod =
                hasObjectGetters
                ? "NSAccessibility object getters" : "NSAccessibility informal protocol"
        }

        private func attribute(_ name: NSAccessibility.Attribute) -> Any? {
            guard let legacy, attributes.contains(name.rawValue) else { return nil }
            // Both public informal-protocol selectors return Objective-C objects, so perform
            // preserves their ABI. No scalar/struct-returning selector is invoked this way.
            return legacy.perform(Self.valueSelector, with: name.rawValue as NSString)?
                .takeUnretainedValue()
        }

        private static func supportsObjectGetter(_ object: NSObject, name: String) -> Bool {
            let selector = NSSelectorFromString(name)
            guard object.responds(to: selector),
                let method = class_getInstanceMethod(type(of: object), selector),
                method_getNumberOfArguments(method) == 2
            else { return false }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            return String(cString: returnType).hasPrefix("@")
        }

        private func objectGetter(_ name: String) -> Any? {
            guard let legacy, Self.supportsObjectGetter(legacy, name: name) else { return nil }
            return legacy.perform(NSSelectorFromString(name))?.takeUnretainedValue()
        }

        private func booleanGetter(_ key: String) -> Bool? {
            guard let legacy else { return nil }
            let selector = NSSelectorFromString("is" + key.prefix(1).uppercased() + key.dropFirst())
            guard legacy.responds(to: selector),
                let method = class_getInstanceMethod(type(of: legacy), selector),
                method_getNumberOfArguments(method) == 2
            else { return nil }
            let returnType = method_copyReturnType(method)
            defer { free(returnType) }
            guard ["B", "c"].contains(String(cString: returnType)) else { return nil }
            // KVC boxes a known Objective-C BOOL getter; perform cannot safely return scalars.
            return (legacy.value(forKey: key) as? NSNumber)?.boolValue
        }

        var role: String {
            modern?.accessibilityRole()?.rawValue ?? objectGetter("accessibilityRole") as? String
                ?? attribute(.role) as? String ?? "unknown"
        }
        var subrole: String? {
            modern?.accessibilitySubrole()?.rawValue ?? objectGetter("accessibilitySubrole")
                as? String ?? attribute(.subrole) as? String
        }
        var label: String? {
            modern?.accessibilityLabel() ?? objectGetter("accessibilityLabel") as? String
                ?? attribute(.description) as? String ?? attribute(.title)
                as? String
        }
        var identifier: String? {
            modern?.accessibilityIdentifier() ?? objectGetter("accessibilityIdentifier") as? String
                ?? attribute(.identifier) as? String
        }
        var value: Any? {
            modern?.accessibilityValue() ?? objectGetter("accessibilityValue") ?? attribute(.value)
        }
        var enabled: Bool {
            modern?.isAccessibilityEnabled() ?? booleanGetter("accessibilityEnabled")
                ?? (attribute(.enabled) as? NSNumber)?.boolValue
                ?? true
        }
        var focused: Bool {
            modern?.isAccessibilityFocused() ?? booleanGetter("accessibilityFocused")
                ?? (attribute(.focused) as? NSNumber)?.boolValue
                ?? false
        }
        var selected: Bool {
            modern?.isAccessibilitySelected() ?? booleanGetter("accessibilitySelected")
                ?? (attribute(.selected) as? NSNumber)?.boolValue
                ?? false
        }
        var children: [Any] {
            modern?.accessibilityChildren() ?? objectGetter("accessibilityChildren") as? [Any]
                ?? attribute(.children) as? [Any] ?? []
        }

        var frame: CGRect? {
            if let modern { return modern.accessibilityFrame() }
            if let partial = legacy as? any NSAccessibilityElementProtocol {
                return partial.accessibilityFrame()
            }
            guard let position = attribute(.position) as? NSValue,
                let size = attribute(.size) as? NSValue,
                String(cString: position.objCType)
                    == String(cString: NSValue(point: .zero).objCType),
                String(cString: size.objCType) == String(cString: NSValue(size: .zero).objCType)
            else { return nil }
            return CGRect(origin: position.pointValue, size: size.sizeValue)
        }
    }

    /// Deliberately bounded so opening feedback does not walk an entire virtualized feed.
    static func collectAccessibility(
        root: AnyObject, maxNodes: Int = 600, maxDepth: Int = 24, maxTextLength: Int = 512,
        timeBudget: TimeInterval = 0.2
    ) -> AccessibilityCapture {
        let started = ProcessInfo.processInfo.systemUptime
        var queue: [(object: AnyObject, depth: Int, parentIndex: Int?)] = [(root, 0, nil)]
        var visited: Set<ObjectIdentifier> = []
        var nodes: [AccessibilityNode] = []
        var cursor = 0
        var unsupported = 0
        var unsupportedTypes: Set<String> = []
        var legacyTypes: Set<String> = []
        var legacyCount = 0
        var secure = 0
        var editable = 0
        var shortened = 0
        var truncatedReasons: Set<String> = []
        func bounded(_ text: String?) -> String? {
            guard let text else { return nil }
            if text.count > maxTextLength { shortened += 1 }
            return String(text.prefix(max(0, maxTextLength)))
        }

        while cursor < queue.count {
            if nodes.count >= maxNodes {
                truncatedReasons.insert("node limit")
                break
            }
            if ProcessInfo.processInfo.systemUptime - started > timeBudget {
                truncatedReasons.insert("time budget")
                break
            }
            let item = queue[cursor]
            cursor += 1
            guard visited.insert(ObjectIdentifier(item.object)).inserted else { continue }
            guard let element = AccessibilityReader(item.object) else {
                unsupported += 1
                if unsupportedTypes.count < 12 {
                    unsupportedTypes.insert(String(reflecting: type(of: item.object)))
                }
                continue
            }
            if element.accessMethod != "NSAccessibilityProtocol" {
                legacyCount += 1
                if legacyTypes.count < 12 {
                    legacyTypes.insert(String(reflecting: type(of: item.object)))
                }
            }
            let role = element.role
            let subrole = element.subrole
            let isSecure =
                subrole == NSAccessibility.Subrole.secureTextField.rawValue
                || item.object is NSSecureTextField
            let isEditable = [
                NSAccessibility.Role.textField.rawValue, NSAccessibility.Role.textArea.rawValue,
                NSAccessibility.Role.comboBox.rawValue,
            ].contains(role)
            var value: String?
            var valueStatus: String
            if isSecure {
                secure += 1
                valueStatus = "redacted: secure input"
            } else if isEditable {
                editable += 1
                valueStatus = "redacted: editable input"
            } else {
                let rawValue = element.value
                if let text = rawValue as? String {
                    value = bounded(text)
                    valueStatus = text.count > maxTextLength ? "truncated" : "success"
                } else if let number = rawValue as? NSNumber {
                    value = number.stringValue
                    valueStatus = "success"
                } else {
                    valueStatus = "unavailable or unsupported type"
                }
            }
            let frame = element.frame.flatMap { frame -> FeedbackRect? in
                guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite,
                    frame.height.isFinite
                else { return nil }
                return FeedbackRect(frame)
            }
            let nodeIndex = nodes.count
            nodes.append(
                AccessibilityNode(
                    role: role, label: isSecure ? nil : bounded(element.label), value: value,
                    frame: frame, depth: item.depth, parentIndex: item.parentIndex,
                    subrole: subrole, identifier: bounded(element.identifier),
                    implementationType: String(reflecting: type(of: item.object)),
                    enabled: element.enabled,
                    focused: element.focused, selected: element.selected, valueStatus: valueStatus,
                    accessMethod: element.accessMethod
                ))
            // Input fields can expose editor/static-text children containing the same input.
            guard !isSecure && !isEditable else { continue }
            let children = element.children
            if item.depth >= maxDepth {
                if !children.isEmpty { truncatedReasons.insert("depth limit") }
                continue
            }
            // Bound the queue as well as output, even if a custom node exposes thousands of children.
            let capacity = max(0, maxNodes * 2 - queue.count)
            if children.count > capacity { truncatedReasons.insert("queue limit") }
            queue.append(
                contentsOf: children.prefix(capacity).map {
                    ($0 as AnyObject, item.depth + 1, nodeIndex)
                })
        }
        var diagnostics: [String] = []
        if !truncatedReasons.isEmpty {
            diagnostics.append(
                "Accessibility tree truncated: \(truncatedReasons.sorted().joined(separator: ", "))."
            )
        }
        if unsupported > 0 {
            diagnostics.append(
                "Accessibility skipped \(unsupported) objects with neither a supported formal nor informal protocol: \(unsupportedTypes.sorted().joined(separator: ", "))."
            )
        }
        let status =
            nodes.isEmpty
            ? "unavailable" : (truncatedReasons.isEmpty && unsupported == 0 ? "success" : "partial")
        return AccessibilityCapture(
            nodes: nodes,
            metadata: [
                "accessibility.status": status,
                "accessibility.method":
                    "In-process NSAccessibilityProtocol with public informal-protocol fallback; no external Accessibility permission required",
                "accessibility.coordinateSpace":
                    "AppKit global screen points, origin at bottom left",
                "accessibility.nodeCount": String(nodes.count),
                "accessibility.unsupportedCount": String(unsupported),
                "accessibility.unsupportedTypes": unsupportedTypes.sorted().joined(separator: ", "),
                "accessibility.legacyNodeCount": String(legacyCount),
                "accessibility.legacyTypes": legacyTypes.sorted().joined(separator: ", "),
                "accessibility.redactedSecureInputs": String(secure),
                "accessibility.redactedEditableInputs": String(editable),
                "accessibility.truncatedTextCount": String(shortened),
                "accessibility.truncationReasons": truncatedReasons.sorted().joined(
                    separator: ", "),
                "accessibility.durationMilliseconds": String(
                    Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)),
                "accessibility.limits":
                    "\(maxNodes) nodes; \(maxDepth) levels; \(maxTextLength) characters/value; \(Int(timeBudget * 1_000)) ms between getters",
                "accessibility.completeness":
                    "Only accessibility exposed by the app is available; virtualized/offscreen and some custom-rendered content may be absent.",
            ], diagnostics: diagnostics)
    }
}
