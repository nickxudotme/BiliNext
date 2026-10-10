import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Login

    func loggedIn() async {
        profile = try? await api.profile()
        for instance in Array(playbackInstances.values) + Array(browseInstances.values) {
            instance.profile = profile
        }
        cachedLists.removeAll()
        folders = []
        folderID = 0
        loginPresented = false
        refresh()
    }
    func logout() async {
        do {
            try await api.logout()
            profile = nil
            for destination in browseInstances.keys {
                tabSubscriptions.removeValue(forKey: "browse:" + destination)
            }
            browseInstances.removeAll()
            cachedLists.removeAll()
            folders = []
            folderID = 0
            removedLater = nil
            videos = []
            for id in Array(playbackInstances.keys) { releasePlaybackTab(id) }
            stopMedia()
            selected = nil
            refresh()
        } catch { browseError = error.localizedDescription }
    }
}
