import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let drawerWidth: CGFloat = 220
    /// Fullscreen and 小窗 drop the inset so video reaches the window edges.
    private var edgeToEdge: Bool { fullScreen || model.miniPlayer }
    private var cardGap: CGFloat { edgeToEdge ? 0 : GlassTheme.cardGap }
    @State private var expandedMenus: Set<BrowseDestination> = []
    private var pinned: Bool {
        get { model.sidebarPinned }
        nonmutating set { model.sidebarPinned = newValue }
    }
    @State private var fullScreen = false
    @State private var pinnedBeforePlaybackFullscreen: Bool?
    @State private var revealed = false
    @State private var hovering = false
    @State private var hideTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var pointerZone = -1
    @StateObject private var tabPreview = TabHoverPreview()

    var body: some View {
        ZStack {
            ForEach(model.browseInstances.keys.sorted(), id: \.self) { pageID in
                if let instance = model.browseInstances[pageID] {
                    let active =
                        model.selected == nil && pageID == model.browsePageID(for: model.menu)
                    BrowseView(model: instance, isActive: active, topInset: BrowseToolbar.height)
                        .developmentFeedbackTarget(
                            "browse.\(pageID)", label: "浏览页：\(pageID)", isActive: active
                        )
                        .id(ObjectIdentifier(instance))
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(active)
                        .accessibilityHidden(!active)
                }
            }
            if model.selected == nil {
                BrowseToolbar(model: model)
                    .developmentFeedbackTarget("browse.toolbar", label: "浏览工具栏")
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            ForEach(model.tabs) { tab in
                if let instance = model.playbackInstances[tab.id] {
                    if let keyword = SearchResultsTab.keyword(tab.id) {
                        SearchResultsView(
                            model: instance, keyword: keyword, isActive: model.selected == tab.id
                        )
                        .developmentFeedbackTarget(
                            "search.\(tab.id)", label: "搜索结果", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    } else if let space = instance.memberSpace {
                        MemberSpaceView(
                            space: space, model: instance, isActive: model.selected == tab.id
                        )
                        .developmentFeedbackTarget(
                            "member.\(tab.id)", label: "UP 主空间", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    } else if let session = instance.liveSession {
                        LiveRoomView(session: session, isActive: model.selected == tab.id)
                            .developmentFeedbackTarget(
                                "live.\(tab.id)", label: "直播页", isActive: model.selected == tab.id
                            )
                            .opacity(model.selected == tab.id ? 1 : 0)
                            .allowsHitTesting(model.selected == tab.id)
                            .accessibilityHidden(model.selected != tab.id)
                    } else {
                        PlaybackTabHost(
                            model: instance, navigationOverlayVisible: !pinned && revealed,
                            miniPlayer: model.miniPlayer, windowPinned: model.windowPinned,
                            isActive: model.selected == tab.id, onExitCommand: exitPlayback
                        )
                        .developmentFeedbackTarget(
                            "playback.\(tab.id)", label: "播放页", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            // Content is an inset card on the wallpaper-tinted backdrop, as in Arc.
            // Fullscreen drops the inset so video and pages reach the screen edges.
            .background(GlassTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: edgeToEdge ? 0 : GlassTheme.cardRadius))
            .shadow(color: .black.opacity(edgeToEdge ? 0 : 0.18), radius: 1.5)
            .padding(.leading, pinned ? drawerWidth : cardGap)
            .padding([.top, .bottom, .trailing], cardGap)
            .background { WindowBackdrop().ignoresSafeArea() }
            .background(
                WindowChrome(
                    pinned: model.windowPinned, miniPlayer: model.miniPlayer,
                    showsButtons: pinned || revealed
                ) { fullScreen = $0 }
            )
            .onChange(of: fullScreen) { _, entered in
                if entered && model.selected != nil {
                    pinnedBeforePlaybackFullscreen = pinned
                    revealTask?.cancel()
                    hideTask?.cancel()
                    pinned = false
                    revealed = false
                    pointerZone = -1
                } else if !entered, let previous = pinnedBeforePlaybackFullscreen {
                    revealTask?.cancel()
                    hideTask?.cancel()
                    pinned = previous
                    revealed = false
                    pointerZone = -1
                    pinnedBeforePlaybackFullscreen = nil
                }
            }
            .background(
                DrawerPointerTracker(externalWidth: drawerWidth) { point in updatePointer(point) }
            )
            .overlay(alignment: .leading) {
                // Keep one view identity through floating/pinned/hidden states.
                // Pinning changes its geometry in place rather than replacing it.
                sidebar.frame(width: drawerWidth)
                    .developmentFeedbackTarget(
                        "navigation.sidebar", label: "导航侧栏", isActive: pinned || revealed
                    )
                    // Animate the parent geometry as one group so child controls
                    // travel with the panel instead of adopting its final layout.
                    .geometryGroup()
                    .background { SidebarSurface(pinned: pinned) }
                    .clipShape(RoundedRectangle(cornerRadius: pinned ? 0 : GlassTheme.panelRadius))
                    .shadow(
                        color: .black.opacity(pinned ? 0 : 0.16), radius: pinned ? 0 : 16, x: 4,
                        y: 4
                    )
                    .padding(.vertical, pinned ? 0 : 4)
                    .padding(.leading, pinned ? 0 : 4)
                    .offset(x: pinned || revealed ? 0 : -(drawerWidth + 40))
                    .opacity(pinned || revealed ? 1 : 0)
                    .allowsHitTesting(pinned || revealed)
                    .accessibilityHidden(!pinned && !revealed)
            }
            .overlayPreferenceValue(TabRowAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let id = tabPreview.tabID, !model.miniPlayer,
                        MemberSpace.mid(id) == nil, SearchResultsTab.keyword(id) == nil,
                        pinned || revealed, let anchor = anchors[id],
                        let tab = model.tabs.first(where: { $0.id == id })
                    {
                        let row = proxy[anchor]
                        let height = TabPreviewCard.width * 9 / 16 + 86
                        TabPreviewCard(
                            tab: tab, preparedCover: tabPreview.cover(for: tab.video.cover)
                        )
                        .position(
                            x: row.maxX + 14 + TabPreviewCard.width / 2,
                            y: min(
                                max(row.midY, height / 2 + 12),
                                proxy.size.height - height / 2 - 12)
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    }
                }
                .animation(Motion.quick(reduceMotion), value: tabPreview.tabID)
            }
            .animation(Motion.panel(reduceMotion), value: pinned)
            .animation(Motion.panel(reduceMotion), value: revealed)
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: model.selected) { _, selected in
                // 小窗 only shows a video; closing the last one returns to the full window.
                if selected == nil && model.miniPlayer { model.toggleMiniPlayer() }
            }
            .onChange(of: model.sidebarPinned) { _, _ in
                // The menu shortcut toggles pinning without passing through the header button.
                revealTask?.cancel()
                hideTask?.cancel()
                revealed = false
                pointerZone = -1
            }
            .onExitCommand(perform: exitPlayback)
            .onDisappear {
                revealTask?.cancel()
                hideTask?.cancel()
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    // Over a video, stay above the floating control bar.
                    let overVideo = model.selected != nil && !model.miniPlayer
                    Text(toast).font(GlassTheme.labelFont)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .chromeSurface(in: Capsule())
                        .padding(.horizontal, 28).padding(.bottom, overVideo ? 108 : 28)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.standard(reduceMotion), value: model.toast)
            .overlay(alignment: .topTrailing) { PerformanceHUDOverlay() }
            .sheet(isPresented: $model.downloadsPresented) {
                DownloadsView(manager: model.downloads, model: model)
            }
            .sheet(isPresented: $model.loginPresented) { LoginView(model: model) }
    }

    private func exitPlayback() {
        if model.miniPlayer {
            model.toggleMiniPlayer()
            return
        }
        revealTask?.cancel()
        hideTask?.cancel()
        if !pinned { revealed = false }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Arc's header: window buttons, the sidebar toggle right after them, then back,
            // forward and reload at the trailing edge, all centred on the window buttons.
            HStack(spacing: 6) {
                if !fullScreen {
                    // The row's own spacing completes the gap after the window buttons.
                    Color.clear.frame(width: WindowButtons.trailingEdge - headerOrigin.x)
                }
                headerButton("sidebar.left", size: 17, label: pinned ? "隐藏侧栏" : "固定侧栏") {
                    revealTask?.cancel()
                    hideTask?.cancel()
                    pinned.toggle()
                    revealed = false
                    pointerZone = -1
                }
                .foregroundStyle(.primary.opacity(0.75))
                Spacer(minLength: 0)
                headerButton("arrow.left", label: "后退") { model.moveHistory(-1) }
                    .disabled(!model.canBack)
                headerButton("arrow.right", label: "前进") { model.moveHistory(1) }
                    .disabled(!model.canForward)
                headerButton("arrow.clockwise", label: "刷新") { model.refresh() }
                    .foregroundStyle(.primary.opacity(0.75))
            }
            .foregroundStyle(.primary.opacity(0.6))
            .frame(height: Self.headerButtonSize)
            .padding(
                .top,
                fullScreen ? 10 : WindowButtons.centerY - headerOrigin.y - Self.headerButtonSize / 2
            )
            .padding(.leading, fullScreen ? 10 : 0).padding(.trailing, 7).padding(.bottom, 12)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(BrowseDestination.sidebarItems, id: \.self) { item in
                        let hasChildren = item.hasSidebarChildren
                        let active = model.menu == item && model.selected == nil
                        HStack(spacing: 0) {
                            Button {
                                model.navigate(item)
                                if hasChildren { expandedMenus = [item] }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.systemImage).font(.system(size: 17))
                                        .frame(
                                            width: 20
                                        )
                                        .foregroundStyle(active ? GlassTheme.accent : .secondary)
                                    Text(item.title)
                                    Spacer(minLength: 0)
                                }.padding(.leading, 10).frame(
                                    height: GlassTheme.navigationRowHeight
                                )
                                .contentShape(Rectangle())
                            }.buttonStyle(InteractionButtonStyle(kind: .row))
                            if hasChildren {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                        if expandedMenus.contains(item) {
                                            expandedMenus.remove(item)
                                        } else {
                                            expandedMenus.insert(item)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .rotationEffect(
                                            .degrees(expandedMenus.contains(item) ? 90 : 0)
                                        )
                                        .foregroundStyle(.secondary).frame(
                                            width: 28, height: GlassTheme.navigationRowHeight)
                                }.buttonStyle(InteractionButtonStyle(kind: .row))
                                    .accessibilityLabel(
                                        (expandedMenus.contains(item) ? "折叠" : "展开") + item.title)
                            }
                        }
                        .background {
                            NavigationSelection(
                                selected: active && !(hasChildren && expandedMenus.contains(item)))
                        }
                        .fontWeight(active ? .semibold : .regular)
                        if hasChildren && expandedMenus.contains(item) {
                            if item == .favorites {
                                SidebarBrowseChildren(page: model, owner: model, destination: item)
                            } else if let page = model.loadedBrowseInstance(for: item) {
                                SidebarBrowseChildren(page: page, owner: model, destination: item)
                            } else {
                                SidebarBrowsePlaceholder(destination: item) { title in
                                    if item == .favorites {
                                        model.navigate(item)
                                    } else {
                                        model.selectBrowseSection(
                                            destination: item, section: title)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { expandedMenus.insert(model.menu) }
            .onChange(of: model.menu) { _, destination in expandedMenus = [destination] }
            SidebarTabList(model: model, sidebarHovered: hovering, preview: tabPreview)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: "person.crop.circle")
                if let profile = model.profile {
                    Text(profile.name).lineLimit(1)
                    Spacer()
                    Menu {
                        Button("下载管理") { model.downloadsPresented = true }
                        Divider()
                        Button("退出登录") { Task { await model.logout() } }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .modifier(MenuHoverFeedback())
                    .frame(width: 28, height: 28)
                    .chromeSurface(in: Circle(), interactive: true)
                    .help("账户选项").accessibilityLabel("账户选项")
                } else {
                    Button("登录 B 站") { model.loginPresented = true }.buttonStyle(
                        InteractionButtonStyle())
                    Spacer()
                }
            }.font(GlassTheme.labelFont).padding(14)
                .overlay(alignment: .top) { Divider().opacity(0.35).padding(.horizontal, 14) }
        }
        .font(GlassTheme.bodyFont)
    }

    private static let headerButtonSize: CGFloat = 28

    /// Where the sidebar's top-left corner sits in the window: flush when pinned, inset when it
    /// floats, so the header stays aligned with the window buttons either way.
    private var headerOrigin: CGPoint { pinned ? .zero : CGPoint(x: 4, y: 4) }

    private func headerButton(
        _ symbol: String, size: CGFloat = 16, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
                .iconControlFrame(size: Self.headerButtonSize)
        }
        .buttonStyle(InteractionButtonStyle())
        .help(label).accessibilityLabel(label)
    }

    private func updatePointer(_ point: NSPoint?) {
        let zone = DrawerActivation.zone(
            x: point?.x, top: point?.y, width: drawerWidth, pinned: pinned, fullScreen: fullScreen)
        let nextHovering = zone == 2 && (pinned || revealed)
        if hovering != nextHovering { hovering = nextHovering }
        guard pointerZone != zone else { return }
        pointerZone = zone
        hideTask?.cancel()
        revealTask?.cancel()
        guard !pinned else { return }
        if zone == 1 && !revealed {
            revealTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled, !pinned, pointerZone == 1 else { return }
                revealed = true
            }
        } else if zone == 0 && revealed {
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, !pinned else { return }
                revealed = false
            }
        }
    }
}
