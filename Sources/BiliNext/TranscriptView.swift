import AVKit
import BiliNextCore
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var clock: PlaybackClock
    init(model: AppModel) {
        self.model = model
        self.clock = model.playbackClock
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
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
        let ids = activeIDs
        return groups.first(where: { group in group.contains { ids.contains($0.id) } })?.first?.id
    }
    var body: some View {
        let groups = self.groups
        let activeIDs = self.activeIDs
        let matchIDs = Set(matches)
        return VStack(spacing: 12) {
            HStack {
                Text("字幕脚本").font(GlassTheme.readingFont.weight(.semibold))
                Spacer()
                Toggle("段落", isOn: $paragraphs).toggleStyle(.switch).controlSize(.small)
                    .font(GlassTheme.labelFont)
            }
            SubtitleTrackControls(model: model)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("搜索字幕", text: $query).textFieldStyle(.plain)
            }.font(GlassTheme.labelFont).padding(8).frame(minHeight: GlassTheme.controlHeight)
                .chromeSurface(in: RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
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
                                .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                            Button {
                                moveMatch(-1, proxy: proxy)
                            } label: {
                                Image(systemName: "chevron.up").font(GlassTheme.labelFont)
                                    .iconControlFrame()
                            }.disabled(matches.isEmpty).accessibilityLabel("上一个匹配").help("上一个匹配")
                            Button {
                                moveMatch(1, proxy: proxy)
                            } label: {
                                Image(systemName: "chevron.down").font(GlassTheme.labelFont)
                                    .iconControlFrame()
                            }.disabled(matches.isEmpty).accessibilityLabel("下一个匹配").help("下一个匹配")
                        }
                        Spacer()
                        Button {
                            following.toggle()
                            if following, let id = activeGroup {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        } label: {
                            Text(following ? "暂停跟随" : "回到正在播放")
                                .font(GlassTheme.metadataFont)
                                .frame(minHeight: GlassTheme.iconControlSize)
                                .contentShape(Rectangle())
                        }
                    }.buttonStyle(InteractionButtonStyle(kind: .row))
                        .padding(.vertical, 4)
                    Divider().opacity(0.4)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(groups, id: \.first!.id) { group in
                                if let first = group.first {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Button {
                                                model.seek(first.start)
                                            } label: {
                                                Text(timestamp(first.start))
                                                    .font(GlassTheme.metadataFont.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                                    .frame(minHeight: GlassTheme.iconControlSize)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(InteractionButtonStyle(kind: .row))
                                            Spacer(minLength: 0)
                                            if group.contains(where: { activeIDs.contains($0.id) })
                                            {
                                                Label("正在播放", systemImage: "waveform")
                                                    .foregroundStyle(GlassTheme.accent)
                                            } else if matchIDs.contains(first.id) {
                                                Label("匹配", systemImage: "magnifyingglass")
                                                    .foregroundStyle(.secondary)
                                            }
                                        }.font(GlassTheme.captionFont)
                                        Text(
                                            group.map(\.text).joined(
                                                separator: paragraphs ? " " : "")
                                        )
                                        .font(GlassTheme.readingFont).lineSpacing(5).textSelection(
                                            .enabled)
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            group.contains { activeIDs.contains($0.id) }
                                                ? GlassTheme.accent.opacity(0.1)
                                                : matchIDs.contains(first.id)
                                                    ? Color.yellow.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                                                .strokeBorder(
                                                    .primary.opacity(
                                                        contrast == .increased
                                                            && (group.contains {
                                                                activeIDs.contains($0.id)
                                                            } || matchIDs.contains(first.id))
                                                            ? 0.4 : 0), lineWidth: 1
                                                )
                                                .allowsHitTesting(false)
                                        }
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
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
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
