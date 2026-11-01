import BiliNextCore
import SwiftUI

struct SearchEntryField: View {
    let api: BilibiliAPI
    @ObservedObject var history: SearchHistoryStore
    var initial = ""
    let submit: (String) -> Void
    @State private var draft = ""
    @State private var suggestions: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索视频、UP 主或 BV 号", text: $draft)
                .textFieldStyle(.plain).focused($focused).onSubmit { search(draft) }
        }
        .padding(.horizontal, 14).frame(width: 260, height: 38)
        .floatingGlass(in: Capsule())
        .overlay(alignment: .top) {
            if focused {
                let items = draft.isEmpty ? Array(history.terms.prefix(8)) : suggestions
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(draft.isEmpty ? "搜索历史" : "搜索联想").foregroundStyle(.secondary)
                            Spacer()
                            if draft.isEmpty {
                                Button("清空") { history.clear() }.buttonStyle(.plain)
                            }
                        }.font(.caption).padding(8)
                        ForEach(items, id: \.self) { term in
                            Button {
                                search(term)
                            } label: {
                                Text(term).lineLimit(1).frame(
                                    maxWidth: .infinity, alignment: .leading
                                ).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(6).frame(width: 300).floatingGlassPanel().offset(y: 44)
                }
            }
        }
        .zIndex(focused ? 10 : 0)
        .onAppear { draft = initial }
        .onChange(of: initial) { _, value in draft = value }
        .task(id: focused ? draft : "") {
            suggestions = []
            guard focused, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let values = try await api.searchSuggestions(draft)
                try Task.checkCancellation()
                suggestions = values
            } catch {}
        }
    }
    private func search(_ term: String) {
        guard !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        history.remember(term)
        focused = false
        draft = term
        submit(term)
    }
}
