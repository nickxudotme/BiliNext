import AppKit
import SwiftUI

/// Retain each tab's SwiftUI state and video surface behind an AppKit layout
/// boundary. Hidden pages must not participate in the shell's sizing/focus walk.
struct PlaybackTabHost: NSViewRepresentable {
    let model: AppModel
    var navigationOverlayVisible: Bool
    var miniPlayer: Bool
    var windowPinned: Bool
    var isActive: Bool
    var onExitCommand: () -> Void

    struct Configuration: Equatable {
        var navigationOverlayVisible: Bool
        var miniPlayer: Bool
        var windowPinned: Bool
        var isActive: Bool
    }

    private var configuration: Configuration {
        Configuration(
            navigationOverlayVisible: isActive && navigationOverlayVisible,
            miniPlayer: miniPlayer, windowPinned: windowPinned, isActive: isActive)
    }

    func makeNSView(context: Context) -> Host {
        Host(model: model, configuration: configuration, onExitCommand: onExitCommand)
    }

    func updateNSView(_ view: Host, context: Context) {
        view.update(model: model, configuration: configuration, onExitCommand: onExitCommand)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Host: NSView {
        private let content: NSHostingView<PlaybackView>
        private var model: AppModel
        private var configuration: Configuration

        init(model: AppModel, configuration: Configuration, onExitCommand: @escaping () -> Void) {
            self.model = model
            self.configuration = configuration
            content = NSHostingView(rootView: Self.page(model, configuration, onExitCommand))
            // The shell supplies the viewport; asking every retained page for its
            // intrinsic/minimum/maximum size traverses all its detail rows.
            content.sizingOptions = []
            // ShellView already lays out the full-size window content. An embedded
            // hosting root must not reserve the titlebar safe area a second time.
            content.safeAreaRegions = []
            super.init(frame: .zero)
            addSubview(content)
            isHidden = !configuration.isActive
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            updateContentFrame()
        }

        private func updateContentFrame() {
            // Retain the last viewport while hidden. Sidebar/window resizing
            // must not reflow every background page and its video surface.
            guard configuration.isActive else { return }
            if content.frame != bounds { content.frame = bounds }
        }

        func update(
            model: AppModel, configuration: Configuration, onExitCommand: @escaping () -> Void
        ) {
            guard self.model !== model || self.configuration != configuration else { return }
            self.model = model
            self.configuration = configuration
            content.rootView = Self.page(model, configuration, onExitCommand)
            // Catch up before unhiding, even if AppKit already laid out the
            // outer host while this tab was inactive.
            updateContentFrame()
            isHidden = !configuration.isActive
        }

        private static func page(
            _ model: AppModel, _ config: Configuration, _ onExitCommand: @escaping () -> Void
        ) -> PlaybackView {
            PlaybackView(
                model: model, navigationOverlayVisible: config.navigationOverlayVisible,
                miniPlayer: config.miniPlayer, windowPinned: config.windowPinned,
                isActive: config.isActive, onExitCommand: onExitCommand)
        }
    }
}
