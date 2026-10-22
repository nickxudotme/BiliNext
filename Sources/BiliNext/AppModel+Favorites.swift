import BiliNextCore
import Foundation

extension AppModel {
    /// Publishes the authoritative folder list after a user-initiated change. Existing
    /// folder pages keep their scroll position and filters unless their folder vanished.
    func favoriteFoldersDidChange(
        _ available: [FavoriteFolder], accountID: Int64, preferredFolderID: Int64? = nil,
        deletedFolderID: Int64? = nil
    ) {
        if let tabOwner {
            tabOwner.favoriteFoldersDidChange(
                available, accountID: accountID, preferredFolderID: preferredFolderID,
                deletedFolderID: deletedFolderID)
            return
        }
        guard profile?.id == accountID else { return }
        resetFavoriteFolderPreload()
        favoriteFoldersAccountID = accountID
        // Opening the 收藏到 picker reads the folders too. When that finds them as every
        // favorites page already has them, nothing changed, and stopping those pages' loads
        // would only interrupt them.
        if preferredFolderID == nil, deletedFolderID == nil, available == folders,
            browseInstances.values.allSatisfy({ $0.menu != .favorites || $0.folders == available })
        {
            return
        }
        let valid = Set(available.map(\.id))
        var removed = Set(folders.map(\.id))
        for instance in browseInstances.values where instance.menu == .favorites {
            removed.formUnion(instance.folders.map(\.id))
            if instance.folderID != 0 { removed.insert(instance.folderID) }
        }
        if folderID != 0 { removed.insert(folderID) }
        removed.subtract(valid)
        if let deletedFolderID { removed.insert(deletedFolderID) }
        let fallback = available.first?.id ?? 0
        var needsReload = false
        for (key, instance) in Array(browseInstances) where instance.menu == .favorites {
            let wasLoading = instance.loading
            instance.browseTask?.cancel()
            instance.browseTask = nil
            instance.browseGeneration = UUID()
            instance.loading = false
            instance.folders = available
            instance.cachedLists = instance.cachedLists.filter { entry in
                !removed.contains { Self.isFavoriteCache(entry.key, folder: $0) }
            }
            if instance.folderID != 0 && !valid.contains(instance.folderID) {
                instance.invalidateBrowseCache()
                browseInstances.removeValue(forKey: key)
                tabSubscriptions.removeValue(forKey: "browse:" + key)
            } else if instance.folderID == 0 && fallback != 0 {
                // A formerly empty library must become loadable after its first folder.
                instance.invalidateBrowseCache()
                instance.folders = available
                instance.folderID = fallback
                needsReload = true
            } else if wasLoading && instance.browseContext == nil {
                instance.browseLoadAttempted = false
                needsReload = true
            }
        }
        folders = available
        cachedLists = cachedLists.filter { entry in
            !removed.contains { Self.isFavoriteCache(entry.key, folder: $0) }
        }
        if folderID != 0 && !valid.contains(folderID) { folderID = fallback }
        var selectedNewFolder = false
        if let preferredFolderID, valid.contains(preferredFolderID),
            menu == .favorites && selected == nil
        {
            selectedNewFolder = folderID != preferredFolderID
            folderID = preferredFolderID
        }
        if !removed.isEmpty {
            let removedRoutes = Set(removed.map { "收藏:\($0)" })
            history = history.map { removedRoutes.contains($0) ? "收藏:\(fallback)" : $0 }
            for player in playbackInstances.values where player.profile?.id == accountID {
                if let video = player.detail?.video { player.loadRelation(for: video.bvid) }
            }
        }
        if menu == .favorites && selected == nil {
            if selectedNewFolder {
                navigate(.favorites)
            } else if let active = loadedBrowseInstance(for: .favorites) {
                if needsReload { active.loadBrowseIfNeeded() }
            } else {
                loadBrowseIfNeeded()
            }
        }
    }

    /// Applies a confirmed membership difference to every retained view of this video.
    /// It also invalidates only the folders whose contents actually changed.
    func favoriteMembershipDidChange(
        aid: Int64, before: Set<Int64>, after: Set<Int64>, accountID: Int64
    ) {
        if let tabOwner {
            tabOwner.favoriteMembershipDidChange(
                aid: aid, before: before, after: after, accountID: accountID)
            return
        }
        guard profile?.id == accountID else { return }
        let changed = before.symmetricDifference(after)
        guard !changed.isEmpty else { return }
        let delta = (after.isEmpty ? 0 : 1) - (before.isEmpty ? 0 : 1)
        for instance in [self] + Array(playbackInstances.values) {
            guard instance.profile?.id == accountID, var detail = instance.detail,
                detail.video.aid == aid
            else { continue }
            instance.relationGeneration = UUID()
            instance.relationReading = false
            instance.relation.favorited = !after.isEmpty
            if delta != 0 {
                detail.stats.favorites = detail.stats.favorites.map { max(0, $0 + delta) }
                instance.detail = detail
            }
        }
        for instance in [self] + Array(browseInstances.values) {
            instance.folders = instance.folders.map { folder in
                guard changed.contains(folder.id) else { return folder }
                var updated = folder
                updated.count = max(0, folder.count + (after.contains(folder.id) ? 1 : -1))
                return updated
            }
            instance.cachedLists = instance.cachedLists.filter { entry in
                !changed.contains { Self.isFavoriteCache(entry.key, folder: $0) }
            }
            if instance !== self, instance.menu == .favorites,
                changed.contains(instance.folderID)
            {
                let available = instance.folders
                instance.invalidateBrowseCache()
                instance.folders = available
            }
        }
        if menu == .favorites && selected == nil { loadBrowseIfNeeded() }
    }

    private static func isFavoriteCache(_ key: String, folder: Int64?) -> Bool {
        guard let folder else { return false }
        return key.hasPrefix("收藏:\(folder):")
    }
}
