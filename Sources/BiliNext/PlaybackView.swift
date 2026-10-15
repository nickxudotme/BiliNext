import AVKit
import BiliNextCore
import Combine
import SwiftUI

private enum PlaybackPanel: String, CaseIterable, Identifiable {
    case info = "简介"
    case comments = "评论"
    case transcript = "字幕"
    case danmaku = "弹幕"
    var id: String { rawValue }

    /// Debug builds can open another panel first for screenshots, e.g. BILINEXT_DEBUG_PANEL=评论.
    static var initial: PlaybackPanel {
        #if DEBUG
            if let name = ProcessInfo.processInfo.environment["BILINEXT_DEBUG_PANEL"],
                let panel = PlaybackPanel(rawValue: name)
            {
                return panel
            }
        #endif
        return .info
    }
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .comments: "bubble.left.and.bubble.right"
        case .transcript: "captions.bubble"
        case .danmaku: "text.bubble"
        }
    }
}

struct PlaybackView: View {
    @ObservedObject var model: AppModel
    var navigationOverlayVisible = false
    var miniPlayer = false
    var windowPinned = false
    var isActive = true
    @State private var panel = PlaybackPanel.initial
    @State private var playerWidth: CGFloat = 0
    @State private var pointer: NSPoint?
    @State private var hoveringVideo = false
    @State private var hoveringDetails = false
    @State private var idle = false
    @State private var idleTask: Task<Void, Never>?
    @AppStorage("playback.panelWidth") private var panelWidth = 372.0
    @State private var dragStartWidth: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
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
                            .font(GlassTheme.iconFont.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 60)
                            .chromeSurface(in: Capsule())
                    }
                    .buttonStyle(InteractionButtonStyle())
                    .help(model.theater ? "展开视频详情" : "收起视频详情")
                    .accessibilityLabel(model.theater ? "展开视频详情" : "收起视频详情")
                    .padding(.trailing, 6)
                    .opacity(detailsToggleVisible ? 1 : 0)
                    .allowsHitTesting(detailsToggleVisible)
                    .accessibilityHidden(!detailsToggleVisible)
                }
            if !model.theater && !miniPlayer {
                detailsPanel
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .floatingGlassPanel()
                    .overlay(alignment: .leading) { resizeHandle }
                    .padding(8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The playback page is a dark screening room lit by the video's own cover.
        .background { PlaybackAmbience(cover: model.detail?.video.cover ?? currentCover) }
        .environment(\.colorScheme, .dark)
        .animation(Motion.emphasized(reduceMotion), value: model.theater)
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
        // Coin and favorite live here so shortcuts work in theater mode too.
        .confirmationDialog("向这部视频投币", isPresented: $model.coinDialogPresented) {
            Button("投 1 枚硬币") { model.coin(1) }
            if model.relation.coins == 0 { Button("投 2 枚硬币") { model.coin(2) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("B 站硬币投出后无法撤回，实际可投数量由视频规则决定。")
        }
        .sheet(
            isPresented: $model.favoritePresented,
            onDismiss: { if let id = model.detail?.video.bvid { model.loadRelation(for: id) } },
            content: {
                if let aid = model.detail?.video.aid { FavoritePickerView(model: model, aid: aid) }
            })
    }

    private var currentCover: URL? {
        model.tabs.first(where: { $0.id == model.selected })?.video.cover
    }

    private var detailsPanel: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 8) {
                    PlaybackPanelSwitcher(selection: $panel)
                    playbackOptions
                }
            }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
            Group {
                switch panel {
                case .info: VideoIntroPanel(model: model)
                case .comments: CommentsPanel(model: model, isActive: isActive).id(model.selected)
                case .transcript: TranscriptView(model: model)
                case .danmaku: DanmakuListView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Dragging the panel's leading edge resizes it, as the split view did.
    private var resizeHandle: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = panelWidth }
                        panelWidth = min(
                            460, max(320, (dragStartWidth ?? panelWidth) - value.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .offset(x: -4)
    }

    private var detailsToggleVisible: Bool {
        !miniPlayer && (hoveringDetails || (hoveringVideo && !idle))
    }

    private var playbackOptions: some View {
        Menu {
            Button("返回浏览") { model.navigate(model.menu) }
            Button(model.officialCore ? "使用原播放器" : "使用本机官方核心") { model.switchPlayer() }
                .disabled(model.pageID == nil)
            Button("复制播放诊断") {
                if let mpv = model.mpv {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(mpv.diagnosticSummary, forType: .string)
                    model.toast = "播放诊断已复制"
                }
            }.disabled(model.mpv == nil || model.officialCore)
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
                CustomPlayerView(
                    model: model, danmaku: model.danmaku, isActive: isActive,
                    miniPlayer: miniPlayer,
                    windowPinned: windowPinned
                ) {
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
                    withAnimation(Motion.emphasized(reduceMotion)) {
                        selection = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(GlassTheme.labelFont.weight(selection == tab ? .semibold : .medium))
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: GlassTheme.controlHeight)
                        .contentShape(Capsule())
                        .background {
                            if selection == tab {
                                Capsule().fill(GlassTheme.raisedFill)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                    .matchedGeometryEffect(id: "selection", in: highlight)
                            }
                        }
                }
                .buttonStyle(InteractionButtonStyle())
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(.primary.opacity(0.06), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("视频详情栏目")
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
