import BiliNextCore
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @State private var items: [Activity] = []
    @State private var offset: String?
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var member: Activity?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                ForEach(items) { activity in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 10) {
                            AvatarView(url: activity.avatar).frame(width: 36, height: 36)
                            Button {
                                member = activity
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(activity.author).font(.headline)
                                    Text(activity.time).font(.caption).foregroundStyle(.secondary)
                                }
                            }.buttonStyle(InteractionButtonStyle(kind: .row)).disabled(
                                activity.mid == nil)
                            Spacer()
                            if let link = activity.link {
                                Link(destination: link) {
                                    Image(systemName: "arrow.up.right.square")
                                }.help("查看完整动态")
                            }
                        }
                        if !activity.text.isEmpty {
                            Text(activity.text).font(.system(size: 14)).lineSpacing(5)
                                .textSelection(.enabled).fixedSize(
                                    horizontal: false, vertical: true)
                        }
                        if let original = activity.original {
                            Text(original).font(.callout).foregroundStyle(.secondary).textSelection(
                                .enabled
                            ).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let video = activity.video {
                            Button {
                                model.open(
                                    video, background: NSEvent.modifierFlags.contains(.command))
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: video.cover) {
                                        $0.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.gray.opacity(0.2)
                                    }.frame(width: 180, height: 105).clipped().clipShape(
                                        RoundedRectangle(cornerRadius: 8))
                                    Text(video.title).font(.callout).lineLimit(3)
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(InteractionButtonStyle(kind: .row))
                        }
                        if !activity.images.isEmpty {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 180), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(activity.images, id: \.absoluteString) { url in
                                    Link(destination: url) {
                                        AsyncImage(url: url) {
                                            $0.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.gray.opacity(0.1)
                                        }.frame(height: 180).clipped().clipShape(
                                            RoundedRectangle(cornerRadius: 8))
                                    }.help("打开原图")
                                }
                            }
                        }
                    }.padding(20).background(
                        .quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 14))
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { load() }
                } else if offset != nil {
                    Button("加载更多动态") { load(append: true) }.frame(maxWidth: .infinity)
                } else if items.isEmpty {
                    ContentUnavailableView("暂无动态", systemImage: "rectangle.stack")
                }
            }.frame(maxWidth: 820).frame(maxWidth: .infinity).padding(.horizontal, 28).padding(
                .bottom, 24)
        }.task(id: model.timelineRefresh) { load() }.onDisappear { task?.cancel() }
            .sheet(item: $member) { activity in
                if let mid = activity.mid {
                    MemberView(model: model, mid: mid, name: activity.author)
                }
            }
    }
    private func load(append: Bool = false) {
        task?.cancel()
        generation = UUID()
        let token = generation
        if !append {
            items = []
            offset = nil
        }
        let cursor = append ? offset : nil
        error = nil
        loading = true
        task = Task { @MainActor in
            do {
                let result = try await model.api.activities(offset: cursor)
                guard !Task.isCancelled, token == generation else { return }
                var seen = Set<String>()
                items = (items + result.items).filter { seen.insert($0.id).inserted }
                offset = result.next == cursor ? nil : result.next
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { loading = false }
        }
    }
}
