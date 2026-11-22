import AppKit
import SwiftUI

/// Keep inactive browse/search/live pages at their last viewport, just like
/// PlaybackTabHost. Opacity alone does not stop SwiftUI laying out hidden grids.
struct RetainedPageHost<Content: View>: NSViewRepresentable {
    var isActive: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> Host {
        Host(content: content(), isActive: isActive)
    }

    func updateNSView(_ view: Host, context: Context) {
        view.update(content: content(), isActive: isActive)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class Host: NSView {
        let content: NSHostingView<Content>
        private var isActive: Bool

        init(content: Content, isActive: Bool) {
            self.content = NSHostingView(rootView: content)
            self.isActive = isActive
            super.init(frame: .zero)
            self.content.sizingOptions = []
            self.content.safeAreaRegions = []
            addSubview(self.content)
            isHidden = !isActive
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            updateContentFrame()
        }

        func update(content: Content, isActive: Bool) {
            self.isActive = isActive
            self.content.rootView = content
            // Catch up before revealing; retain the hosting root and scroll state.
            updateContentFrame()
            isHidden = !isActive
        }

        private func updateContentFrame() {
            guard isActive else { return }
            if content.frame != bounds { content.frame = bounds }
        }
    }
}
