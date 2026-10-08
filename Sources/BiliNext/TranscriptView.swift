import AVKit
import BiliNextCore
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var paragraphs = false
    @State private var following = true
    @State private var searchIndex = 0
    private var activeIDs: Set<Int> { Set(model.cues.filter { $0.contains(model.time) }.map(\.id)) }
    private var groups: [[Cue]] {
        paragraphs ? Cue.paragraphs(model.cues) : model.cues.map { [$0] }
    }
    private var matches: [Int] {
        groups.compactMap { group in
            guard let id = group.first?.id, !query.isEmpty,
                group.map(\.text).joined().localizedCaseInsensitiveContains(query)
            else { return nil }
            return id
        }
    }
    private var activeGroup: Int? {
        groups.first(where: { group in group.contains { activeIDs.contains($0.id) } })?.first?.id
    }
    var body: some View {
        let groups = self.groups
        let activeIDs = self.activeIDs
        let matchIDs = Set(matches)
        return VStack(spacing: 12) {
            HStack {
                Text("字幕脚本").font(.headline)
                Spacer()
                Toggle("段落", isOn: $paragraphs).toggleStyle(.switch).controlSize(.mini)
            }
            if !model.tracks.isEmpty {
                Picker(
                    "字幕", selection: Binding(get: { model.trackID }, set: { model.selectTrack($0) })
                ) { ForEach(model.tracks) { track in Text(track.language).tag(track.id) } }
                .labelsHidden()
            }
            TextField("搜索字幕", text: $query).textFieldStyle(.roundedBorder)
            if model.subtitleLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = model.subtitleError {
                ContentUnavailableView(
                    "字幕加载失败", systemImage: "exclamationmark.bubble", description: Text(error))
            } else if model.cues.isEmpty {
                ContentUnavailableView(
                    "暂无可用字幕", systemImage: "captions.bubble",
                    description: Text("此视频没有返回可用字幕，仍可正常观看。"))
            } else {
                ScrollViewReader { proxy in
                    HStack {
                        if !query.isEmpty {
                            Text(matches.isEmpty ? "无匹配" : "\(searchIndex + 1) / \(matches.count)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button {
                                moveMatch(-1, proxy: proxy)
                            } label: {
                                Image(systemName: "chevron.up")
                            }.disabled(matches.isEmpty)
                            Button {
                                moveMatch(1, proxy: proxy)
                            } label: {
                                Image(systemName: "chevron.down")
                            }.disabled(matches.isEmpty)
                        }
                        Spacer()
                        Button(following ? "暂停跟随" : "回到正在播放") {
                            following.toggle()
                            if following, let id = activeGroup {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }.font(.caption)
                    }.buttonStyle(.plain)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(groups, id: \.first!.id) { group in
                                if let first = group.first {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Button(timestamp(first.start)) { model.seek(first.start) }
                                            .font(.caption.monospacedDigit()).foregroundStyle(
                                                .secondary
                                            ).buttonStyle(.plain)
                                        Text(
                                            group.map(\.text).joined(
                                                separator: paragraphs ? " " : "")
                                        )
                                        .font(.system(size: 14)).lineSpacing(5).textSelection(
                                            .enabled)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            group.contains { activeIDs.contains($0.id) }
                                                ? Color.accentColor.opacity(0.1)
                                                : matchIDs.contains(first.id)
                                                    ? Color.yellow.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .id(first.id)
                                        .contextMenu { Button("复制带时间的引用") { copy(group) } }
                                }
                            }
                        }
                    }
                    .onScrollPhaseChange { _, phase in
                        if phase == .interacting { following = false }
                    }
                    .onChange(of: activeGroup) { _, id in
                        if following, let id {
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                    .onChange(of: query) { _, _ in
                        searchIndex = 0
                        following = false
                        if let id = matches.first { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: paragraphs) { _, _ in
                        searchIndex = 0
                        if let id = activeGroup { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }.padding(16)
            .onChange(of: model.pageID) { _, _ in
                query = ""
                following = true
                searchIndex = 0
            }
    }
    private func moveMatch(_ delta: Int, proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        searchIndex = (searchIndex + delta + matches.count) % matches.count
        following = false
        proxy.scrollTo(matches[searchIndex], anchor: .center)
    }
    private func copy(_ group: [Cue]) {
        guard let first = group.first, let id = model.selected else { return }
        let page = model.detail?.pages.first(where: { $0.cid == model.pageID })?.number ?? 1
        let text =
            "\(group.map(\.text).joined(separator: " "))\n\(timestamp(first.start)) · https://www.bilibili.com/video/\(id)?p=\(page)&t=\(Int(first.start))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
