import AppKit
import SwiftUI

struct LiveRoomView: View {
    @ObservedObject var session: LiveSession
    var isActive = true
    @State private var showChat = true
    @State private var chatBeforeFullscreen: Bool?

    var body: some View {
        HSplitView {
            LivePlaybackView(session: session, isActive: isActive, chatVisible: showChat) {
                showChat.toggle()
            }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            if showChat {
                LiveChatView(chat: session.chat, session: session) { showChat = false }
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 400, maxHeight: .infinity)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)
        ) { _ in
            guard isActive else { return }
            chatBeforeFullscreen = showChat
            showChat = false
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)
        ) { _ in
            guard isActive, let previous = chatBeforeFullscreen else { return }
            showChat = previous
            chatBeforeFullscreen = nil
        }
    }
}
