import SwiftUI

/// A stable hosting root preserves retained pages while the shell moves.
struct ShellPages: View {
    @ObservedObject var model: AppModel
    let navigationOverlayVisible: Bool
    let edgeToEdge: Bool
    let onExitCommand: () -> Void

    var body: some View {
        ZStack {
            ForEach(model.browseInstances.keys.sorted(), id: \.self) { pageID in
                if let instance = model.browseInstances[pageID] {
                    let active =
                        model.selected == nil && pageID == model.browsePageID(for: model.menu)
                    RetainedPageHost(isActive: active) {
                        BrowseView(
                            model: instance, isActive: active, topInset: BrowseToolbar.height
                        )
                        .tint(GlassTheme.accent)
                    }
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
                        RetainedPageHost(isActive: model.selected == tab.id) {
                            SearchResultsView(
                                model: instance, keyword: keyword,
                                isActive: model.selected == tab.id
                            )
                            .tint(GlassTheme.accent)
                        }
                        .developmentFeedbackTarget(
                            "search.\(tab.id)", label: "搜索结果", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    } else if let space = instance.memberSpace {
                        RetainedPageHost(isActive: model.selected == tab.id) {
                            MemberSpaceView(
                                space: space, model: instance, isActive: model.selected == tab.id
                            )
                            .tint(GlassTheme.accent)
                        }
                        .developmentFeedbackTarget(
                            "member.\(tab.id)", label: "UP 主空间", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    } else if let session = instance.liveSession {
                        RetainedPageHost(isActive: model.selected == tab.id) {
                            LiveRoomView(session: session, isActive: model.selected == tab.id)
                                .tint(GlassTheme.accent)
                        }
                        .developmentFeedbackTarget(
                            "live.\(tab.id)", label: "直播页", isActive: model.selected == tab.id
                        )
                        .opacity(model.selected == tab.id ? 1 : 0)
                        .allowsHitTesting(model.selected == tab.id)
                        .accessibilityHidden(model.selected != tab.id)
                    } else {
                        PlaybackTabHost(
                            model: instance, navigationOverlayVisible: navigationOverlayVisible,
                            miniPlayer: model.miniPlayer, windowPinned: model.windowPinned,
                            isActive: model.selected == tab.id, onExitCommand: onExitCommand
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
            // Content is an inset card on the opaque window backdrop.
            // Fullscreen drops the inset so video and pages reach the screen edges.
            .background(GlassTheme.canvas)
            .clipShape(RoundedRectangle(cornerRadius: edgeToEdge ? 0 : GlassTheme.cardRadius))
            .shadow(color: .black.opacity(edgeToEdge ? 0 : 0.18), radius: 1.5)

            .onExitCommand(perform: onExitCommand)
    }

}
