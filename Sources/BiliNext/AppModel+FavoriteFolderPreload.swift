import BiliNextCore
import Foundation

extension AppModel {
    func resetFavoriteFolderPreload() {
        favoriteFoldersTask?.cancel()
        favoriteFoldersTask = nil
        favoriteFoldersGeneration = UUID()
        favoriteFoldersAccountID = nil
        favoriteFoldersLoading = false
        favoriteFoldersError = nil
    }

    func acceptFavoriteFolders(_ available: [FavoriteFolder]) {
        resetFavoriteFolderPreload()
        folders = available
        favoriteFoldersAccountID = profile?.id
        for page in browseInstances.values where page.menu == .favorites {
            page.folders = available
        }
    }

    /// Fetch only sidebar metadata; this never creates a page or requests its videos.
    func preloadFavoriteFolders() {
        guard managesPlaybackTabs, let accountID = profile?.id,
            favoriteFoldersAccountID != accountID, !favoriteFoldersLoading
        else { return }
        let account = accountGeneration
        let generation = UUID()
        favoriteFoldersGeneration = generation
        favoriteFoldersLoading = true
        favoriteFoldersError = nil
        favoriteFoldersTask = Task { [weak self, favoriteFolderLoader] in
            do {
                let available = try await favoriteFolderLoader(accountID)
                guard let self, !Task.isCancelled, self.accountGeneration == account,
                    self.profile?.id == accountID, self.favoriteFoldersGeneration == generation
                else { return }
                self.folders = available
                self.favoriteFoldersAccountID = accountID
                for page in self.browseInstances.values where page.menu == .favorites {
                    page.folders = available
                }
                self.favoriteFoldersLoading = false
                self.favoriteFoldersTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.accountGeneration == account,
                    self.favoriteFoldersGeneration == generation
                else { return }
                self.favoriteFoldersError = error.localizedDescription
                self.favoriteFoldersLoading = false
                self.favoriteFoldersTask = nil
            }
        }
    }
}
