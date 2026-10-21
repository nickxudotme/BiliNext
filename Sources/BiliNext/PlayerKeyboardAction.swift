import SwiftUI

/// Key handlers run inside SwiftUI's update cycle. Acknowledge the event immediately,
/// then publish model changes on the next main-queue turn, in event order.
@MainActor
enum PlayerKeyboardAction {
    static func enqueue(model: AppModel, action: @escaping @MainActor () -> Void) -> KeyPress.Result
    {
        guard model.playbackTabActive else { return .ignored }
        let generation = model.videoGeneration
        DispatchQueue.main.async {
            guard model.playbackTabActive, model.videoGeneration == generation else { return }
            action()
        }
        return .handled
    }
}
