import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Login

    func loggedIn() async {
        accountGeneration = UUID()
        let account = accountGeneration
        let loadedProfile = try? await api.profile()
        guard account == accountGeneration else { return }
        profile = loadedProfile
        historyOutbox.accountChanged()
        for instance in playbackInstances.values {
            instance.profile = profile
        }
        for (pageID, instance) in browseInstances {
            instance.invalidateBrowseCache()
            tabSubscriptions.removeValue(forKey: "browse:" + pageID)
        }
        browseInstances.removeAll()
        cachedLists.removeAll()
        folders = []
        folderID = 0
        loginPresented = false
        refresh()
    }
    func logout() async {
        do {
            try await api.logout()
            accountGeneration = UUID()
            profile = nil
            historyOutbox.accountChanged()
            for (pageID, instance) in browseInstances {
                instance.invalidateBrowseCache()
                tabSubscriptions.removeValue(forKey: "browse:" + pageID)
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
