/// Optional feedback intent, stored separately from the user's original description.
public enum FeedbackCategory: String, Codable, CaseIterable, Sendable {
    case bug
    case suggestion
    case question

    var title: String {
        switch self {
        case .bug: "🐛 出错"
        case .suggestion: "💡 建议"
        case .question: "🤔 疑问"
        }
    }
}
