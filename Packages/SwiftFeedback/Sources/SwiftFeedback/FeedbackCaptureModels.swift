import AppKit

/// A rectangle in points. The containing field documents its coordinate space.
public struct FeedbackRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// Accessibility frames use AppKit global screen coordinates (origin at bottom left).
public struct AccessibilityNode: Codable, Sendable {
    public let role: String
    public let label: String?
    public let value: String?
    public let frame: FeedbackRect?
    public let depth: Int
    public let parentIndex: Int?
    public let subrole: String?
    public let identifier: String?
    public let implementationType: String
    public let enabled: Bool
    public let focused: Bool
    public let selected: Bool
    public let valueStatus: String
    public let accessMethod: String

    public init(
        role: String, label: String?, value: String?, frame: FeedbackRect?, depth: Int,
        parentIndex: Int? = nil, subrole: String? = nil, identifier: String? = nil,
        implementationType: String = "", enabled: Bool = true, focused: Bool = false,
        selected: Bool = false, valueStatus: String = "unavailable",
        accessMethod: String = "NSAccessibilityProtocol"
    ) {
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.depth = depth
        self.parentIndex = parentIndex
        self.subrole = subrole
        self.identifier = identifier
        self.implementationType = implementationType
        self.enabled = enabled
        self.focused = focused
        self.selected = selected
        self.valueStatus = valueStatus
        self.accessMethod = accessMethod
    }
}

public struct FeedbackLogEntry: Codable, Sendable {
    public let timestamp: Date
    public let level: String
    public let subsystem: String
    public let category: String
    public let message: String

    public init(
        timestamp: Date, level: String, subsystem: String, category: String, message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.subsystem = subsystem
        self.category = category
        self.message = message
    }
}

public struct CapturedWindow: @unchecked Sendable {
    public let image: CGImage?
    public let metadata: [String: String]
    public let accessibility: [AccessibilityNode]
    public let diagnostics: [String]
    public let logs: [FeedbackLogEntry]

    public init(
        image: CGImage?, metadata: [String: String], accessibility: [AccessibilityNode],
        diagnostics: [String],
        logs: [FeedbackLogEntry] = []
    ) {
        self.image = image
        self.metadata = metadata
        self.accessibility = accessibility
        self.diagnostics = diagnostics
        self.logs = logs
    }
}
