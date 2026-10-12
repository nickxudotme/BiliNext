import BiliNextCore
import SwiftUI

struct SeasonBrowser: View {
    @ObservedObject var model: AppModel
    @State private var type = 1
    @State private var order = 3
    @State private var page = 0
    @State private var seasons: [Season] = []
    @State private var selected: Season?
    @State private var loading = false
    @State private var more = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("类型", selection: $type) {
                    Text("番剧").tag(1)
                    Text("国创").tag(4)
                    Text("纪录片").tag(3)
                    Text("电影").tag(2)
                    Text("电视剧").tag(5)
                }.pickerStyle(.segmented)
                Picker("排序", selection: $order) {
                    Text("追番人数").tag(3)
                    Text("更新时间").tag(0)
                    Text("最高评分").tag(4)
                }.frame(width: 160)
            }.controlSize(.large).font(GlassTheme.labelFont).padding(.horizontal, 28)
            if let error {
                HStack {
                    Text(error)
                    Button("重试") { load() }.controlSize(.large).font(GlassTheme.labelFont)
                }.font(GlassTheme.metadataFont).padding(.horizontal, 28)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 20)], spacing: 24) {
                    ForEach(seasons) { season in
                        Button {
                            selected = season
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Color.gray.opacity(0.1).aspectRatio(0.72, contentMode: .fit).overlay
                                {
                                    AsyncImage(url: season.cover) {
                                        $0.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.clear
                                    }
                                }.clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(season.title).font(GlassTheme.bodyFont).lineLimit(1)
                                Text(
                                    [season.update, season.badge].filter { !$0.isEmpty }.joined(
                                        separator: " · ")
                                ).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 28)
                if loading {
                    ProgressView().padding()
                } else if more {
                    Button("加载更多") { load(append: true) }.controlSize(.large)
                        .font(GlassTheme.labelFont).padding()
                }
            }
        }.task(id: model.catalogRefresh) { load() }.onChange(of: type) { _, _ in load() }.onChange(
            of: order
        ) { _, _ in load() }.onDisappear { task?.cancel() }
            .sheet(item: $selected) { SeasonDetailView(model: model, season: $0) }
    }
    private func load(append: Bool = false) {
        task?.cancel()
        generation = UUID()
        let token = generation
        if !append {
            page = 0
            seasons = []
            more = false
        }
        let next = page + 1
        let kind = type
        let sort = order
        error = nil
        loading = true
        task = Task { @MainActor in
            do {
                let result = try await model.api.seasons(type: kind, page: next, order: sort)
                guard !Task.isCancelled, token == generation else { return }
                var seen = Set<Int64>()
                seasons = (seasons + result).filter { seen.insert($0.id).inserted }
                page = next
                more = result.count >= 20
            } catch {
                guard !Task.isCancelled, token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { loading = false }
        }
    }
}

private struct SeasonDetailView: View {
    @ObservedObject var model: AppModel
    let season: Season
    @Environment(\.dismiss) private var dismiss
    @State private var detail: SeasonDetail?
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(season.title).font(.title2.bold())
                Spacer()
                Button("完成") { dismiss() }.controlSize(.large).font(GlassTheme.labelFont)
                    .keyboardShortcut(.cancelAction)
            }
            if loading { ProgressView() }
            if let error {
                Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                Button("重试") { Task { await load() } }.controlSize(.large).font(
                    GlassTheme.labelFont)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(detail?.description ?? "").font(GlassTheme.readingFont).lineSpacing(5)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ForEach(detail?.episodes ?? []) { video in
                        Button {
                            model.open(video)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "play.circle").font(.system(size: 20))
                                Text(video.title).font(GlassTheme.bodyFont)
                                Spacer()
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if let detail, detail.episodes.isEmpty {
                        Text("当前没有返回可播放的正片。").font(GlassTheme.bodyFont).foregroundStyle(.secondary)
                    }
                    Link(
                        "在 B 站查看",
                        destination: URL(
                            string: "https://www.bilibili.com/bangumi/play/ss\(season.id)")!
                    )
                    .font(GlassTheme.labelFont).frame(minHeight: GlassTheme.controlHeight)
                }
            }
        }.padding(24).frame(width: 660, height: 500).task { await load() }
    }
    private func load() async {
        loading = true
        error = nil
        do { detail = try await model.api.season(id: season.id) } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
