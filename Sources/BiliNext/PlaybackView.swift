import AVKit
import BiliNextCore
import Combine
import SwiftUI

private enum PlaybackPanel: String, CaseIterable, Identifiable {
    case info = "简介"
    case comments = "评论"
    case related = "推荐"
    case transcript = "字幕"
    case danmaku = "弹幕"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .comments: "bubble.left.and.bubble.right"
        case .related: "play.rectangle.on.rectangle"
        case .transcript: "captions.bubble"
        case .danmaku: "text.bubble"
        }
    }
}

struct PlaybackView: View {
    @ObservedObject var model: AppModel
    var navigationOverlayVisible = false
    var isActive = true
    @State private var panel = PlaybackPanel.info
    @State private var playerWidth: CGFloat = 0
    @State private var pointer: NSPoint?
    @State private var hoveringVideo = false
    @State private var hoveringDetails = false
    @State private var idle = false
    @State private var idleTask: Task<Void, Never>?

    var body: some View {
        HSplitView {
            player
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    playerWidth = $0
                }
                .overlay(alignment: .trailing) {
                    Button {
                        model.theater.toggle()
                        idle = false
                        updateCursor()
                    } label: {
                        Image(systemName: model.theater ? "chevron.left" : "chevron.right")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 64)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(InteractionButtonStyle())
                    .help(model.theater ? "展开视频详情" : "收起视频详情")
                    .accessibilityLabel(model.theater ? "展开视频详情" : "收起视频详情")
                    .padding(.trailing, 6)
                    .opacity(hoveringDetails || (hoveringVideo && !idle) ? 1 : 0)
                    .allowsHitTesting(hoveringDetails || (hoveringVideo && !idle))
                    .accessibilityHidden(!(hoveringDetails || (hoveringVideo && !idle)))
                }
            if !model.theater {
                VStack(spacing: 0) {
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 8) {
                            PlaybackPanelSwitcher(selection: $panel)
                            playbackOptions
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 8)
                    Divider().opacity(0.5)
                    Group {
                        switch panel {
                        case .info: VideoInformationView(model: model)
                        case .comments:
                            VideoCommunityView(model: model, section: "评论").id(model.selected)
                        case .related:
                            VideoCommunityView(model: model, section: "相关推荐").id(model.selected)
                        case .transcript: TranscriptView(model: model)
                        case .danmaku: DanmakuListView(model: model)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }.frame(minWidth: 310, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
                    .background { DetailSurface() }
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DrawerPointerTracker(externalWidth: 0, onPosition: trackPointer))
        .onChange(of: isActive) { _, active in
            idleTask?.cancel()
            pointer = nil
            hoveringVideo = false
            hoveringDetails = false
            if active { NSCursor.setHiddenUntilMouseMoves(false) }
        }
        .onChange(of: model.playing) { _, _ in
            idle = false
            scheduleIdle()
            updateCursor()
        }
        .onChange(of: navigationOverlayVisible) { _, _ in
            let current = pointer
            pointer = nil
            trackPointer(current)
        }
        .onDisappear {
            idleTask?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
        }
    }

    private var playbackOptions: some View {
        Menu {
            Button("返回浏览") { model.navigate(model.menu) }
            Button(model.officialCore ? "使用原播放器" : "使用本机官方核心") { model.switchPlayer() }
                .disabled(model.pageID == nil)
            if let id = model.selected,
                let url = URL(string: "https://www.bilibili.com/video/\(id)")
            {
                Link("在浏览器打开", destination: url)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .modifier(MenuHoverFeedback())
        .frame(width: 36, height: 36)
        .chromeSurface(in: Circle(), interactive: true)
        .help("播放选项").accessibilityLabel("播放选项")
    }

    private func trackPointer(_ next: NSPoint?) {
        guard isActive, next != pointer else { return }
        pointer = next
        let next = navigationOverlayVisible && (next?.x ?? 999) < 224 ? nil : next
        hoveringVideo = next.map { $0.x >= 0 && $0.x < playerWidth } ?? false
        hoveringDetails = next.map { $0.x >= playerWidth && !model.theater } ?? false
        idle = false
        scheduleIdle()
        updateCursor()
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        guard model.officialCore, hoveringVideo && model.playing else { return }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, hoveringVideo, model.playing else { return }
            idle = true
            updateCursor()
        }
    }

    private func updateCursor() {
        guard isActive else { return }
        NSCursor.setHiddenUntilMouseMoves(idle && hoveringVideo && model.playing)
    }
    private var player: some View {
        ZStack {
            Color.black
            if model.officialCore {
                OfficialClientPlayerView(model: model)
                if !model.officialPlayerStatus.isEmpty {
                    Text(model.officialPlayerStatus).font(.callout).foregroundStyle(.white)
                        .padding(14).background(
                            .black.opacity(0.8), in: RoundedRectangle(cornerRadius: 10)
                        ).allowsHitTesting(false)
                }
            } else {
                CustomPlayerView(model: model, danmaku: model.danmaku, isActive: isActive) {
                    visible in
                    idle = !visible && hoveringVideo && model.playing
                    updateCursor()
                }
            }
        }
    }
}

private struct PlaybackPanelSwitcher: View {
    @Binding var selection: PlaybackPanel
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PlaybackPanel.allCases) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(GlassTheme.labelFont.weight(selection == tab ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: GlassTheme.controlHeight)
                        .contentShape(Capsule())
                        .background {
                            if selection == tab {
                                Capsule().fill(.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                }
                .buttonStyle(InteractionButtonStyle())
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(4)
        .chromeSurface(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频详情栏目")
    }
}

private struct VideoInformationView: View {
    @ObservedObject var model: AppModel
    @State private var memberPresented = false
    @State private var favoritePresented = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let detail = model.detail {
                    let video = detail.video
                    Button {
                        memberPresented = true
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(url: video.avatar).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(video.author).font(GlassTheme.bodyFont.weight(.semibold))
                                Text("查看 UP 主主页").font(GlassTheme.metadataFont).foregroundStyle(
                                    .secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(
                                .tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(InteractionButtonStyle()).disabled(video.ownerID == nil)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(video.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(video.bvid) · \(timestamp(model.duration))").font(
                            GlassTheme.metadataFont.monospacedDigit()
                        ).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        if video.episodeID == nil {
                            VideoActions(model: model, video: video).id(video.bvid)
                        }
                        Button {
                            if model.profile == nil {
                                model.loginPresented = true
                            } else {
                                favoritePresented = true
                            }
                        } label: {
                            VideoActionLabel(title: "收藏", systemImage: "star")
                        }.help("收藏到文件夹").accessibilityLabel("收藏到文件夹").disabled(video.aid == nil)
                        Button {
                            model.changeWatchLater(video)
                        } label: {
                            VideoActionLabel(title: "稍后", systemImage: "text.badge.plus")
                        }.help("加入稍后再看").accessibilityLabel("加入稍后再看").disabled(
                            model.libraryBusy.contains(video.id))
                        Button {
                            if let cid = model.pageID {
                                model.downloads.start(
                                    video: video, cid: cid, quality: model.qualityID, api: model.api
                                )
                                model.downloadsPresented = true
                            }
                        } label: {
                            VideoActionLabel(title: "缓存", systemImage: "arrow.down.circle")
                        }.help("缓存当前分 P").accessibilityLabel("缓存当前分 P").disabled(
                            model.pageID == nil)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                "https://www.bilibili.com/video/\(video.bvid)?t=\(Int(model.time))",
                                forType: .string)
                            model.toast = "已复制当前时间链接"
                        } label: {
                            VideoActionLabel(title: "复制", systemImage: "square.and.arrow.up")
                        }.help("复制当前时间链接").accessibilityLabel("复制当前时间链接")
                    }.buttonStyle(InteractionButtonStyle()).font(.system(size: 18)).frame(
                        maxWidth: .infinity)
                    Divider()
                    if !detail.description.isEmpty {
                        Text(detail.description).font(GlassTheme.bodyFont).lineSpacing(5)
                            .textSelection(
                                .enabled
                            ).fixedSize(horizontal: false, vertical: true)
                    }
                    if detail.pages.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("选集 · \(detail.pages.count)").font(
                                GlassTheme.bodyFont.weight(.semibold))
                            ForEach(detail.pages) { page in
                                Button {
                                    model.selectPage(page.cid)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(
                                            systemName: model.pageID == page.cid
                                                ? "waveform" : "play.circle")
                                        Text("P\(page.number)  \(page.title)").lineLimit(2)
                                        Spacer(minLength: 0)
                                    }.font(GlassTheme.labelFont).padding(10).frame(minHeight: 40)
                                        .contentShape(Rectangle())
                                        .background(
                                            model.pageID == page.cid
                                                ? Color.accentColor.opacity(0.1)
                                                : Color.primary.opacity(0.035),
                                            in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(InteractionButtonStyle()).foregroundStyle(
                                    model.pageID == page.cid ? Color.accentColor : .primary)
                            }
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }.padding(20)
        }
        .sheet(isPresented: $memberPresented) {
            if let video = model.detail?.video, let mid = video.ownerID {
                MemberView(model: model, mid: mid, name: video.author)
            }
        }
        .sheet(isPresented: $favoritePresented) {
            if let aid = model.detail?.video.aid { FavoritePickerView(model: model, aid: aid) }
        }
    }
}

private struct DanmakuListView: View {
    @ObservedObject var model: AppModel
    private let clock: PlaybackClock
    @State private var segment: Int
    init(model: AppModel) {
        self.model = model
        self.clock = model.playbackClock
        self._segment = State(initialValue: Int(max(0, model.time) / 360) + 1)
    }

    @State private var items: [Danmaku] = []
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?
    @State private var retry = 0
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("弹幕列表").font(GlassTheme.readingFont.weight(.semibold))
                Spacer()
                Text("当前 6 分钟 · \(items.count) 条").font(GlassTheme.metadataFont).foregroundStyle(
                    .secondary)
            }
            TextField("搜索当前时段弹幕", text: $query).font(GlassTheme.bodyFont).textFieldStyle(
                .roundedBorder
            ).controlSize(.large)
            if loading { ProgressView().controlSize(.small) }
            if let error {
                Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                Button("重试") { retry += 1 }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        items.filter {
                            query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)
                        }
                    ) { item in
                        Button {
                            model.seek(item.time)
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(timestamp(item.time)).font(
                                    GlassTheme.metadataFont.monospacedDigit()
                                )
                                .foregroundStyle(.secondary).frame(
                                    width: 48, alignment: .leading)
                                Text(item.text).font(GlassTheme.bodyFont).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }.buttonStyle(InteractionButtonStyle()).help("跳转到 \(timestamp(item.time))")
                        Divider().opacity(0.3)
                    }
                    if items.isEmpty && !loading && error == nil {
                        ContentUnavailableView("当前时段暂无弹幕", systemImage: "text.bubble")
                    }
                }
            }
        }.padding(16)
            .onReceive(clock.$time.map { Int(max(0, $0) / 360) + 1 }.removeDuplicates()) {
                segment = $0
            }
            .task(id: "\(model.pageID ?? 0):\(segment):\(retry)") {
                items = []
                error = nil
                guard let cid = model.pageID else { return }
                loading = true
                do {
                    let result = try await model.api.danmaku(cid: cid, segment: segment)
                    guard !Task.isCancelled else { return }
                    items = result
                    loading = false
                } catch {
                    if !Task.isCancelled {
                        self.error = error.localizedDescription
                        loading = false
                    }
                }
            }
    }
}
