import Foundation

@MainActor
final class SearchHistoryStore: ObservableObject {
    @Published private(set) var terms: [String]
    private let defaults: UserDefaults
    private let key = "search.recentTerms"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = Array((defaults.stringArray(forKey: key) ?? []).prefix(20))
    }
    func remember(_ raw: String) {
        let term = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !term.isEmpty else { return }
        terms = Array(([term] + terms.filter { $0 != term }).prefix(20))
        defaults.set(terms, forKey: key)
    }
    func clear() {
        terms = []
        defaults.removeObject(forKey: key)
    }
}
