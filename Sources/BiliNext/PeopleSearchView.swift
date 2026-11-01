import BiliNextCore
import SwiftUI

struct PeopleSearchView: View {
    @ObservedObject var model: AppModel
    let keyword: String
    @State private var people: [SearchPerson] = []
    @State private var page = 1
    @State private var retry = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(people) { person in
                    Button {
                        model.openSpace(
                            mid: person.id, name: person.name, avatar: person.avatar,
                            background: NSEvent.modifierFlags.contains(.command))
                    } label: {
                        HStack(spacing: 14) {
                            AvatarView(url: person.avatar).frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(person.name).font(.headline)
                                Text(person.biography).lineLimit(2).foregroundStyle(.secondary)
                                Text("\(person.followers) 位粉丝").font(.caption).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.padding(16).contentShape(Rectangle())
                    }.buttonStyle(InteractionButtonStyle(kind: .row))
                }
                if loading { ProgressView().padding() }
                if let error {
                    ErrorBanner(message: error) { retry += 1 }
                } else if hasMore && !loading {
                    Button("加载更多用户") { page += 1 }.buttonStyle(.glass)
                } else if people.isEmpty && !loading {
                    ContentUnavailableView(
                        "没有找到相关用户", systemImage: "person.crop.circle", description: Text("换个关键词试试。")
                    )
                }
            }.padding(20)
        }
        .task(id: "\(keyword):\(model.accountGeneration):\(page):\(retry)") {
            loading = true
            error = nil
            defer { if !Task.isCancelled { loading = false } }
            do {
                let result = try await model.api.searchPeople(keyword, page: page)
                try Task.checkCancellation()
                var seen = Set<Int64>()
                people = ((page == 1 ? [] : people) + result.people).filter {
                    seen.insert($0.id).inserted
                }
                hasMore = result.hasMore && !result.people.isEmpty
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
