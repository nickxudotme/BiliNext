import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Login

    func loggedIn() async {
        saveSession()
        let resumePreloads = tabPreloadsEnabled
        cancelAllTabPreloads()
        accountGeneration = UUID()
        for id in Array(playbackInstances.keys) { releasePlaybackTab(id) }
        resetFavoriteFolderPreload()
        let account = accountGeneration
        let loadedProfile = try? await api.profile()
        guard account == accountGeneration else { return }
        profile = loadedProfile
        historyOutbox.accountChanged()
        for (pageID, instance) in browseInstances {
            instance.invalidateBrowseCache()
            tabSubscriptions.removeValue(forKey: "browse:" + pageID)
        }
        browseInstances.removeAll()
        cachedLists.removeAll()
        folders = []
        folderID = 0
        preloadFavoriteFolders()
        loginPresented = false
        refresh()
        if resumePreloads { startTabPreloads() }
    }
    func logout() async {
        do {
            try await api.logout()
            saveSession()
            let resumePreloads = tabPreloadsEnabled
            cancelAllTabPreloads()
            accountGeneration = UUID()
            resetFavoriteFolderPreload()
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
            if resumePreloads { startTabPreloads() }
        } catch { browseError = error.localizedDescription }
    }
}
