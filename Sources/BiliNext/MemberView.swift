import BiliNextCore
import SwiftUI

struct MemberView: View {
    @ObservedObject var model: AppModel
    let mid: Int64
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var profile: MemberProfile?
    @State private var videos: [Video] = []
    @State private var keyword = ""
    @State private var order = "pubdate"
    @State private var page = 0
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                AvatarView(url: profile?.avatar).frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile?.name ?? name).font(GlassTheme.sheetTitleFont)
                    Text(profile?.signature ?? "UP 主的投稿").font(GlassTheme.metadataFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Link("B 站空间", destination: URL(string: "https://space.bilibili.com/\(mid)")!)
                    .font(GlassTheme.labelFont).frame(minHeight: GlassTheme.controlHeight)
                Button("完成") { dismiss() }.controlSize(.large).font(GlassTheme.labelFont)
                    .keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField("搜索此 UP 主的视频", text: $keyword).textFieldStyle(.roundedBorder).onSubmit {
                    load()
                }
                Picker("排序", selection: $order) {
                    Text("最新发布").tag("pubdate")
                    Text("最多播放").tag("click")
                    Text("最多收藏").tag("stow")
                }.frame(width: 160)
            }.controlSize(.large).font(GlassTheme.labelFont)
            if let error {
                Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                Button("重试") { load() }.controlSize(.large).font(GlassTheme.labelFont)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 20)], spacing: 24) {
                    ForEach(videos) { video in
                        Button {
                            model.open(video)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Color.gray.opacity(0.15).aspectRatio(16.0 / 9.0, contentMode: .fit)
                                    .overlay {
                                        AsyncImage(url: video.cover) {
                                            $0.resizable().scaledToFill()
                                        } placeholder: {
                                            Color.clear
                                        }
                                    }.clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(video.title).font(GlassTheme.bodyFont).lineSpacing(3)
                                    .lineLimit(2)
                                    .frame(height: 48, alignment: .top)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(InteractionButtonStyle(kind: .row))
                    }
                }
                if loading {
                    ProgressView().padding()
                } else if more {
                    Button("加载更多") { load(append: true) }.controlSize(.large)
                        .font(GlassTheme.labelFont).padding()
                } else if videos.isEmpty && error == nil {
                    ContentUnavailableView("暂无投稿", systemImage: "play.rectangle")
                }
            }
        }.padding(24).frame(width: 780, height: 600)
            .task {
                profile = try? await model.api.member(mid: mid)
                load()
            }
            .onChange(of: order) { _, _ in load() }
            .onDisappear { task?.cancel() }
    }
    private func load(append: Bool = false) {
        task?.cancel()
        generation = UUID()
        let token = generation
        if !append {
            videos = []
            page = 0
            more = false
        }
        loading = true
        error = nil
        let next = page + 1
        let query = keyword
        let sort = order
        task = Task { @MainActor in
            do {
                let result = try await model.api.memberVideos(
                    mid: mid, page: next, keyword: query, order: sort)
                guard !Task.isCancelled, token == generation else { return }
                var seen = Set<String>()
                videos = (videos + result.videos).filter { seen.insert($0.id).inserted }
                page = next
                more = result.next != nil
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { loading = false }
        }
    }
}

struct FavoritePickerView: View {
    @ObservedObject var model: AppModel
    let aid: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteSelection] = []
    @State private var selected = Set<Int64>()
    @State private var original = Set<Int64>()
    @State private var loading = true
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("收藏到文件夹").font(GlassTheme.readingFont.weight(.semibold))
            if loading { ProgressView() }
            if let error { Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(folders) { folder in
                        Toggle(
                            folder.title,
                            isOn: Binding(
                                get: { selected.contains(folder.id) },
                                set: {
                                    if $0 {
                                        selected.insert(folder.id)
                                    } else {
                                        selected.remove(folder.id)
                                    }
                                })
                        )
                        .font(GlassTheme.bodyFont).frame(minHeight: GlassTheme.iconControlSize)
                    }
                }
            }
            if loaded && folders.isEmpty {
                Text("暂无收藏夹，请先在 B 站创建。").font(GlassTheme.bodyFont).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                if !loaded && !loading { Button("重试") { Task { await load() } } }
                Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(loading || !loaded)
            }.controlSize(.large).font(GlassTheme.labelFont)
        }.padding(24).frame(width: 360, height: 360).task { await load() }
    }
    private func load() async {
        guard let mid = model.profile?.id else {
            error = "请先登录"
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            folders = try await model.api.favoriteSelection(mid: mid, aid: aid)
            original = Set(folders.filter(\.selected).map(\.id))
            selected = original
            loaded = true
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func save() {
        loading = true
        error = nil
        Task { @MainActor in
            do {
                try await model.api.saveFavorites(
                    aid: aid, add: selected.subtracting(original),
                    remove: original.subtracting(selected))
                dismiss()
            } catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
