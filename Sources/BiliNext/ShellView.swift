import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let drawerWidth: CGFloat = 220
    @State private var expandedMenus: Set<String> = []
    @State private var pinned = true
    @State private var fullScreen = false
    @State private var pinnedBeforePlaybackFullscreen: Bool?
    @State private var revealed = false
    @State private var hovering = false
    @State private var hoveredTab: String?
    @State private var hideTask: Task<Void, Never>?
    @State private var revealTask: Task<Void, Never>?
    @State private var pointerZone = -1
    private let menus = [
        ("首页", "house"), ("搜索", "magnifyingglass"), ("动态", "rectangle.stack"), ("收藏", "star"),
        ("历史", "clock.arrow.circlepath"), ("稍后再看", "clock"),
    ]

    var body: some View {
        ZStack {
            ForEach(model.browseInstances.keys.sorted(), id: \.self) { destination in
                if let instance = model.browseInstances[destination] {
                    BrowseView(
                        model: instance,
                        isActive: model.selected == nil && model.menu == destination
                    )
                    .opacity(model.selected == nil && model.menu == destination ? 1 : 0)
                    .allowsHitTesting(model.selected == nil && model.menu == destination)
                    .accessibilityHidden(model.selected != nil || model.menu != destination)
                }
            }
            ForEach(model.tabs) { tab in
                if let instance = model.playbackInstances[tab.id] {
                    PlaybackView(
                        model: instance, navigationOverlayVisible: !pinned && revealed,
                        isActive: model.selected == tab.id
                    )
                    .opacity(model.selected == tab.id ? 1 : 0)
                    .allowsHitTesting(model.selected == tab.id)
                    .accessibilityHidden(model.selected != tab.id)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, pinned ? drawerWidth : 0)
            .background(GlassTheme.canvas)
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
                    Text(toast).font(.callout).padding(12).chromeSurface(in: Capsule()).padding(20)
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled { model.toast = nil }
                        }
                }
            }
            .sheet(isPresented: $model.downloadsPresented) {
                DownloadsView(manager: model.downloads, model: model)
            }
            .sheet(isPresented: $model.loginPresented) { LoginView(model: model) }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 4) {
                    if !fullScreen {
                        TrafficLights().frame(width: 56, height: 24)
                    }
                    Button {
                        revealTask?.cancel()
                        hideTask?.cancel()
                        pinned.toggle()
                        revealed = false
                        pointerZone = -1
                    } label: {
                        Image(systemName: "sidebar.left").frame(width: 28, height: 32)
                    }
                    .chromeSurface(in: Circle(), interactive: true)
                    .help(pinned ? "隐藏侧栏" : "固定侧栏")
                    .accessibilityLabel(pinned ? "隐藏侧栏" : "固定侧栏")
                    Spacer(minLength: 0)
                    HStack(spacing: 2) {
                        Button {
                            model.moveHistory(-1)
                        } label: {
                            Image(systemName: "arrow.left").frame(width: 26, height: 32)
                        }
                        .disabled(!model.canBack).accessibilityLabel("后退")
                        Button {
                            model.moveHistory(1)
                        } label: {
                            Image(systemName: "arrow.right").frame(width: 26, height: 32)
                        }
                        .disabled(!model.canForward).accessibilityLabel("前进")
                        Button {
                            model.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise").frame(width: 26, height: 32)
                        }
                        .accessibilityLabel("刷新")
                    }.padding(.horizontal, 3)
                        .chromeSurface(in: Capsule(), interactive: true)
                }
                .font(.system(size: 15)).buttonStyle(InteractionButtonStyle())
                .frame(height: 44).padding(.horizontal, 10)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(menus, id: \.0) { item in
                        let hasChildren = ["首页", "动态", "收藏"].contains(item.0)
                        let active = model.menu == item.0 && model.selected == nil
                        HStack(spacing: 0) {
                            Button {
                                model.navigate(item.0)
                                if hasChildren { expandedMenus = [item.0] }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: item.1).font(.system(size: 17)).frame(
                                        width: 20
                                    )
                                    .foregroundStyle(active ? GlassTheme.accent : .secondary)
                                    Text(item.0)
                                    Spacer(minLength: 0)
                                }.padding(.leading, 10).frame(
                                    height: GlassTheme.navigationRowHeight
                                )
                                .contentShape(Rectangle())
                            }.buttonStyle(InteractionButtonStyle(kind: .row))
                            if hasChildren {
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                        if expandedMenus.contains(item.0) {
                                            expandedMenus.remove(item.0)
                                        } else {
                                            expandedMenus.insert(item.0)
                                        }
                                    }
                                } label: {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 11, weight: .semibold))
                                        .rotationEffect(
                                            .degrees(expandedMenus.contains(item.0) ? 90 : 0)
                                        )
                                        .foregroundStyle(.secondary).frame(
                                            width: 28, height: GlassTheme.navigationRowHeight)
                                }.buttonStyle(InteractionButtonStyle(kind: .row))
                                    .accessibilityLabel(
                                        (expandedMenus.contains(item.0) ? "折叠" : "展开") + item.0)
                            }
                        }
                        .background {
                            NavigationSelection(selected: active && !expandedMenus.contains(item.0))
                        }
                        .fontWeight(active ? .semibold : .regular)
                        if hasChildren && expandedMenus.contains(item.0) {
                            if let page = model.browseInstances[item.0] {
                                SidebarBrowseChildren(page: page, owner: model, destination: item.0)
                            } else {
                                SidebarBrowsePlaceholder(destination: item.0) { title in
                                    model.navigate(item.0)
                                    let page = model.browseInstance(for: item.0)
                                    if item.0 == "首页" { page.homeSection = title }
                                    if item.0 == "动态" { page.dynamicMode = title }
                                    page.refresh()
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
                                    "https://www.bilibili.com/video/\(tab.id)", forType: .string
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
