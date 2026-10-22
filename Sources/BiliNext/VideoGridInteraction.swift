import Combine
import Foundation

/// Shared scroll/idle behavior for native grids; layout and pagination stay with each grid.
@MainActor
final class VideoGridInteraction: ObservableObject {
    @Published var scrolling = false
    private var idleWork: DispatchWorkItem?

    func beginScrolling(stopPreview: () -> Void) {
        if !scrolling {
            scrolling = true
            stopPreview()
        }
        cancelIdle()
        let work = DispatchWorkItem { [weak self] in self?.finishScrolling() }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func cancelIdle() {
        idleWork?.cancel()
        idleWork = nil
    }

    func finishScrolling() {
        cancelIdle()
        if scrolling { scrolling = false }
    }
}
