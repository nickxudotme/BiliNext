import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let drawerWidth: CGFloat = 220
    private var cardGap: CGFloat { fullScreen ? 0 : GlassTheme.cardGap }
    @State private var expandedMenus: Set<BrowseDestination> = []
    @State private var pinned = true
    @State private var fullScreen = false
    @State private var pinnedBeforePlaybackFullscreen: Bool?
    @State private var revealed = false
    @State private var hovering = false
    @State private var hoveredTab: String?
    @State private var hideTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var pointerZone = -1

    var body: some View {
        ZStack {
            ForEach(model.browseInstances.keys.sorted(), id: \.self) { pageID in
                if let instance = model.browseInstances[pageID] {
                    let active =
                        model.selected == nil && pageID == model.browsePageID(for: model.menu)
                    BrowseView(
                        model: instance,
                        isActive: active
                    )
                    .padding(.top, BrowseToolbar.height)
                    .id(ObjectIdentifier(instance))
                    .opacity(active ? 1 : 0)
                    .allowsHitTesting(active)
                    .accessibilityHidden(!active)
                }
            }
            if model.selected == nil {
                BrowseToolbar(model: model)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            ForEach(model.tabs) { tab in
                if let instance = model.playbackInstances[tab.id] {
                    if let session = instance.liveSession {
                        LiveRoomView(session: session, isActive: model.selected == tab.id)
                            .opacity(model.selected == tab.id ? 1 : 0)
                            .allowsHitTesting(model.selected == tab.id)
                            .accessibilityHidden(model.selected != tab.id)
                    } else {
                        PlaybackView(
                            model: instance, navigationOverlayVisible: !pinned && revealed,
                            isActive: model.selected == tab.id
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
            .clipShape(RoundedRectangle(cornerRadius: fullScreen ? 0 : GlassTheme.cardRadius))
            .shadow(color: .black.opacity(fullScreen ? 0 : 0.18), radius: 1.5)
            .padding(.leading, pinned ? drawerWidth : cardGap)
            .padding([.top, .bottom, .trailing], cardGap)
            .background { WindowBackdrop().ignoresSafeArea() }
            .background(WindowChrome { fullScreen = $0 })
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
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: pinned)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: revealed)
            .ignoresSafeArea(.container, edges: .top)
            .onExitCommand {
                revealTask?.cancel()
                hideTask?.cancel()
                if !pinned { revealed = false }
            }
            .onDisappear {
                revealTask?.cancel()
                hideTask?.cancel()
            }
            .overlay(alignment: .bottom) {
                if let toast = model.toast {
                    Text(toast).font(GlassTheme.labelFont)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .chromeSurface(in: Capsule()).padding(28)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled { model.toast = nil }
                        }
                }
            }
            .animation(Motion.standard(reduceMotion), value: model.toast)
            .sheet(isPresented: $model.downloadsPresented) {
                DownloadsView(manager: model.downloads, model: model)
            }
            .sheet(isPresented: $model.loginPresented) { LoginView(model: model) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if !fullScreen {
                    // Room for the system window buttons, which stay in the titlebar.
                    Color.clear.frame(width: 64, height: 24)
                }
                headerButton("sidebar.left", label: pinned ? "隐藏侧栏" : "固定侧栏") {
                    revealTask?.cancel()
                    hideTask?.cancel()
                    pinned.toggle()
                    revealed = false
                    pointerZone = -1
                }
                Spacer(minLength: 0)
                headerButton("chevron.left", label: "后退") { model.moveHistory(-1) }
                    .disabled(!model.canBack)
                headerButton("chevron.right", label: "前进") { model.moveHistory(1) }
                    .disabled(!model.canForward)
                headerButton("arrow.clockwise", label: "刷新") { model.refresh() }
            }
            // Centre the row on the system window buttons (16pt from the window top).
            .frame(height: fullScreen || pinned ? 32 : 24)
            .padding(.top, fullScreen ? 8 : 0).padding(.horizontal, 8).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(BrowseDestination.allCases, id: \.self) { item in
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
                            if let page = model.loadedBrowseInstance(for: item) {
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
            HStack(spacing: 8) {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                if hovering && !model.tabs.isEmpty {
                    Button("clear") { model.clearTabs() }
                        .buttonStyle(InteractionButtonStyle()).font(GlassTheme.captionFont)
                        .foregroundStyle(.secondary)
                        .help(model.selected == nil ? "清空打开的标签，可撤销" : "清空其他标签，保留当前视频，可撤销")
                }
            }.frame(height: 24).padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        HStack(spacing: 6) {
                            AvatarView(url: tab.video.avatar).frame(width: 20, height: 20)
                            Text(tab.video.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            if model.isPlaying(tab.id) {
                                Button {
                                    model.togglePlayback()
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 12))
                                        .iconControlFrame(size: 24)
                                }.buttonStyle(InteractionButtonStyle()).help("暂停")
                            }
                            if hoveredTab == tab.id {
                                Button {
                                    model.close(tab.id)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 11))
                                        .iconControlFrame(size: 24)
                                }
                                .buttonStyle(InteractionButtonStyle(destructive: true)).help("关闭标签")
                                .accessibilityLabel(
                                    "关闭 \(tab.video.title)")
                            }
                        }.font(GlassTheme.labelFont).padding(.horizontal, 10).frame(
                            height: GlassTheme.tabRowHeight
                        )
                        .background {
                            NavigationSelection(selected: model.selected == tab.id)
                                .background(
                                    .primary.opacity(hoveredTab == tab.id ? 0.04 : 0),
                                    in: RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
                        }
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.16),
                            value: hoveredTab == tab.id
                        )
                        .contentShape(Rectangle()).onTapGesture {
                            model.activate(tab.id, autoplay: true)
                        }
                        .onHover { inside in hoveredTab = inside ? tab.id : nil }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(tab.video.title)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.activate(tab.id, autoplay: true) }
                        .help(tab.video.title)
                        .contextMenu {
                            Button("关闭标签") { model.close(tab.id) }
                            Button("复制链接") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    LiveSession.roomID(tab.id).map {
                                        "https://live.bilibili.com/\($0)"
                                    }
                                        ?? "https://www.bilibili.com/video/\(tab.id)",
                                    forType: .string
                                )
                            }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            if !model.closed.isEmpty {
                Button("撤销关闭") { model.undoClose() }
                    .buttonStyle(InteractionButtonStyle(kind: .row)).foregroundStyle(.secondary)
                    .padding(12)
                    .keyboardShortcut("z", modifiers: .command)
            }
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

    private func headerButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(GlassTheme.iconFont.weight(.medium))
                .foregroundStyle(.secondary).iconControlFrame(size: 30)
        }
        .buttonStyle(InteractionButtonStyle())
        .help(label).accessibilityLabel(label)
    }

    private func updatePointer(_ point: NSPoint?) {
        let zone = DrawerActivation.zone(x: point?.x, width: drawerWidth, pinned: pinned)
        hovering = zone == 2 && (pinned || revealed)
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
