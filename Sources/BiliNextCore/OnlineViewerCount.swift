import Foundation

/// `total` includes all clients; `count` only describes viewers in the web player.
public struct OnlineViewerCount: Equatable, Sendable {
    /// Keep the server's compact form, such as `10万+`, rather than inventing precision.
    public let total: String

    public init?(data: [String: Any]) {
        if let switches = data["show_switch"] as? [String: Any],
            let visible = switches["total"] as? Bool, !visible
        {
            return nil
        }
        let text: String
        if let value = data["total"] as? String {
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let value = data["total"] as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID()
        {
            text = value.stringValue
        } else {
            return nil
        }
        guard
            text.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:万|亿)?\+?$"#, options: .regularExpression) != nil
        else { return nil }
        total = text
    }
}
