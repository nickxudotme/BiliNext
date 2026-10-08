import AppKit
import SwiftUI

struct ShellView: View {
    @ObservedObject var model: AppModel
    private let drawerWidth: CGFloat = 220
    @State private var pinned = true
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
            BrowseView(model: model).opacity(model.selected == nil ? 1 : 0).allowsHitTesting(
                model.selected == nil
            ).accessibilityHidden(model.selected != nil)
            if model.selected != nil {
                PlaybackView(
                    model: model, navigationPinned: pinned, showNavigation: { revealed.toggle() })
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, pinned ? drawerWidth : 0)
            .background(Color(nsColor: .windowBackgroundColor))
            .background(WindowChrome())
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
                    .background {
                        RoundedRectangle(cornerRadius: pinned ? 0 : 14, style: .continuous)
                            .fill(.clear)
                            .glassEffect(
                                .regular, in: RoundedRectangle(cornerRadius: pinned ? 0 : 14))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: pinned ? 0 : 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: pinned ? 0 : 14, style: .continuous)
                            .strokeBorder(.white.opacity(pinned ? 0 : 0.15), lineWidth: 1)
                    }
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
            .animation(.easeInOut(duration: 0.18), value: pinned)
            .animation(.easeInOut(duration: 0.18), value: revealed)
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
                    Text(toast).font(.callout).padding(12).glassEffect().padding(20).task(id: toast)
                    {
                        try? await Task.sleep(for: .seconds(2))
                        if !Task.isCancelled { model.toast = nil }
                    }
                }
            }
            .sheet(isPresented: $model.downloadsPresented) {
                DownloadsView(manager: model.downloads, model: model)
            }
            .sheet(isPresented: $model.loginPresented) { LoginView(model: model) }
            .overlay(alignment: .topTrailing) {
                if !pinned && model.selected == nil {
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: "sidebar.left")
                    }.buttonStyle(.glass).padding(12).help("显示侧栏").keyboardShortcut(
                        "s", modifiers: [.command, .shift])
                }
            }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TrafficLights().frame(width: 56, height: 24)
                Button {
                    revealTask?.cancel()
                    hideTask?.cancel()
                    pinned.toggle()
                    revealed = false
                    pointerZone = -1
                } label: {
                    Image(systemName: "sidebar.left").frame(width: 26, height: 28)
                }
                .help(pinned ? "隐藏侧栏" : "固定侧栏")
                .accessibilityLabel(pinned ? "隐藏侧栏" : "固定侧栏")
                Spacer(minLength: 0)
                Button {
                    model.moveHistory(-1)
                } label: {
                    Image(systemName: "arrow.left").frame(width: 24, height: 28)
                }
                .disabled(!model.canBack).accessibilityLabel("后退")
                Button {
                    model.moveHistory(1)
                } label: {
                    Image(systemName: "arrow.right").frame(width: 24, height: 28)
                }
                .disabled(!model.canForward).accessibilityLabel("前进")
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 24, height: 28)
                }
                .accessibilityLabel("刷新")
            }
            .font(.system(size: 14)).buttonStyle(.plain)
            .frame(height: 44).padding(.horizontal, 10)
            VStack(spacing: 2) {
                ForEach(menus, id: \.0) { item in
                    Button {
                        model.navigate(item.0)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: item.1).frame(width: 16)
                            Text(item.0)
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 10).frame(height: 32)
                            .contentShape(Rectangle())
                            .background(
                                model.menu == item.0 && model.selected == nil
                                    ? Color.primary.opacity(0.075) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 8)
            HStack(spacing: 8) {
                Rectangle().fill(.primary.opacity(0.10)).frame(height: 1)
                if hovering && !model.tabs.isEmpty {
                    Button("clear") { model.clearTabs() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .help("清空打开的标签，可撤销")
                }
            }.frame(height: 24).padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                        HStack(spacing: 8) {
                            AvatarView(url: tab.video.avatar).frame(width: 16, height: 16)
                            Text(tab.video.title).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            if model.isPlaying(tab.id) {
                                Button {
                                    model.togglePlayback()
                                } label: {
                                    Image(systemName: "speaker.wave.2.fill").font(.system(size: 10))
                                }.buttonStyle(.plain).help("暂停")
                            }
                            if hoveredTab == tab.id {
                                Button {
                                    model.close(tab.id)
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 9))
                                }
                                .buttonStyle(.plain).help("关闭标签").accessibilityLabel(
                                    "关闭 \(tab.video.title)")
                            }
                        }.padding(.horizontal, 10).frame(height: 32)
                            .background(
                                model.selected == tab.id
                                    ? Color.primary.opacity(0.09)
                                    : hoveredTab == tab.id ? Color.primary.opacity(0.04) : .clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle()).onTapGesture { model.activate(tab.id) }
                            .onHover { inside in hoveredTab = inside ? tab.id : nil }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(tab.video.title)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.activate(tab.id) }
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
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(12)
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
                    }.menuStyle(.borderlessButton).frame(width: 20)
                } else {
                    Button("登录 B 站") { model.loginPresented = true }.buttonStyle(.plain)
                    Spacer()
                }
            }.font(.system(size: 12)).padding(14)
        }
        .font(.system(size: 13))
    }

    private func updatePointer(_ point: NSPoint?) {
        let zone: Int
        if let point, point.x >= -drawerWidth {
            // The external activation area is exactly one drawer width.
            zone = point.x < 0 ? 1 : (point.x <= (drawerWidth + (pinned ? 0 : 4)) ? 2 : 0)
        } else {
            zone = 0
        }
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
