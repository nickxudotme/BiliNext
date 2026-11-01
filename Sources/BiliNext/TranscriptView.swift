import AVKit
import BiliNextCore
import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: AppModel
    private let clock: PlaybackClock
    let isActive: Bool
    init(model: AppModel, isActive: Bool = true) {
        self.model = model
        self.clock = model.playbackClock
        self.isActive = isActive
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var query = ""
    @State private var paragraphs = false
    @State private var following = true
    @State private var searchIndex = 0
    @State private var index = TranscriptIndex()
    @State private var activeIDs = Set<Int>()
    private var groups: [[Cue]] { index.groups }
    private var matches: [Int] { index.matches }
    private var activeGroup: Int? { index.activeGroup(for: activeIDs) }

    private func updateIndex() {
        index.update(cues: model.cues, paragraphs: paragraphs, query: query)
        let next = index.activeIDs(at: clock.time)
        if next != self.activeIDs { self.activeIDs = next }
    }
    var body: some View {
        let groups = self.groups
        let activeIDs = self.activeIDs
        let matchIDs = Set(matches)
        return VStack(spacing: 12) {
            HStack {
                Text("字幕脚本").font(GlassTheme.readingFont.weight(.semibold))
                Spacer()
                Button("复制全部", systemImage: "doc.on.doc") { model.copyTranscript() }
                    .font(GlassTheme.metadataFont)
                    .buttonStyle(InteractionButtonStyle(kind: .row))
                    .disabled(!model.canCopyTranscript)
                    .help("复制当前视频（当前分 P）的完整主字幕，保留原始换行，不受搜索和段落模式影响")
                    .accessibilityLabel("复制全部字幕脚本")
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
                                transcriptRow(group, activeIDs: activeIDs, matchIDs: matchIDs)
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
                        updateIndex()
                        searchIndex = 0
                        following = false
                        if let id = matches.first { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onChange(of: paragraphs) { _, _ in
                        updateIndex()
                        searchIndex = 0
                        if let id = activeGroup { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }.padding(16)
            .onChange(of: model.cues, initial: true) { _, _ in updateIndex() }
            .onChange(of: query) { _, _ in updateIndex() }
            .onChange(of: paragraphs) { _, _ in updateIndex() }
            .onChange(of: isActive) { _, active in if active { updateIndex() } }
            .onReceive(clock.$time) { time in
                guard isActive else { return }
                let next = index.activeIDs(at: time)
                if next != self.activeIDs { self.activeIDs = next }
            }
            .onChange(of: model.pageID) { _, _ in
                query = ""
                following = true
                searchIndex = 0
            }
    }
    private func transcriptRow(_ group: [Cue], activeIDs: Set<Int>, matchIDs: Set<Int>) -> some View
    {
        let first = group[0]
        let playing = group.contains { activeIDs.contains($0.id) }
        let matched = matchIDs.contains(first.id)
        let text = group.map(\.text).joined(separator: paragraphs ? " " : "")
        return VStack(alignment: .leading, spacing: 6) {
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
                if playing {
                    Label("正在播放", systemImage: "waveform")
                        .foregroundStyle(GlassTheme.accent)
                } else if matched {
                    Label("匹配", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }.font(GlassTheme.captionFont)
            Text(text)
                .font(GlassTheme.readingFont).lineSpacing(5).textSelection(
                    .enabled)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(
                playing
                    ? GlassTheme.accent.opacity(0.1)
                    : matched
                        ? Color.yellow.opacity(0.12) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                    .strokeBorder(
                        .primary.opacity(
                            contrast == .increased && (playing || matched)
                                ? 0.4 : 0), lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .id(first.id)
            .contextMenu { Button("复制带时间的引用") { copy(group) } }
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
