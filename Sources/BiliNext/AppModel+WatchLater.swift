import BiliNextCore
import Foundation

/// The workspace owns mutation ordering; retained pages remain the sources of their lists.
@MainActor
final class WatchLaterSynchronization {
    struct Context: Equatable {
        let accountID: Int64
        let accountGeneration: UUID
        let revision: Int
    }

    private struct Change {
        let video: Video
        let removed: Bool
        let index: Int
        let revision: Int

        func apply(to videos: [Video]) -> [Video] {
            if removed { return videos.filter { $0.id != video.id } }
            guard !videos.contains(where: { $0.id == video.id }) else { return videos }
            var updated = videos
            updated.insert(video, at: min(index, updated.count))
            return updated
        }
    }

    private var context: Context?
    private var changes: [String: Change] = [:]
    private var pending: [String: UUID] = [:]
    private var dirtyPages: [ObjectIdentifier: Int] = [:]
    var busy: Set<String> { Set(pending.keys) }

    func reset() {
        context = nil
        changes = [:]
        pending = [:]
        dirtyPages = [:]
    }

    func prepare(accountID: Int64, generation: UUID) -> Context {
        if context?.accountID != accountID || context?.accountGeneration != generation {
            context = Context(accountID: accountID, accountGeneration: generation, revision: 0)
            changes = [:]
            pending = [:]
            dirtyPages = [:]
        }
        return context!
    }

    func begin(_ id: String) -> UUID? {
        guard pending[id] == nil else { return nil }
        let token = UUID()
        pending[id] = token
        return token
    }

    func finish(_ id: String, token: UUID) {
        guard pending[id] == token else { return }
        pending.removeValue(forKey: id)
    }

    func record(_ video: Video, removed: Bool, index: Int?) {
        guard let context else { return }
        let revision = context.revision + 1
        let previous = changes[video.id]
        changes[video.id] = Change(
            video: video, removed: removed,
            index: index ?? (previous?.removed == true ? previous?.index : nil) ?? 0,
            revision: revision)
        self.context = Context(
            accountID: context.accountID, accountGeneration: context.accountGeneration,
            revision: revision)
    }

    func applyLatest(_ id: String, to videos: [Video]) -> [Video] {
        changes[id]?.apply(to: videos) ?? videos
    }

    /// A read already in flight must not undo a subsequently confirmed write.
    func reconcile(_ videos: [Video], since read: Context) -> [Video] {
        changes.values.filter { $0.revision > read.revision }
            .sorted { $0.revision < $1.revision }
            .reduce(videos) { $1.apply(to: $0) }
    }

    func changed(_ page: AppModel) {
        dirtyPages[ObjectIdentifier(page)] = context?.revision
    }

    func needsPaginationRestart(_ page: AppModel) -> Bool {
        dirtyPages[ObjectIdentifier(page)] != nil
    }

    func acceptedRead(_ page: AppModel, context: Context) {
        let id = ObjectIdentifier(page)
        if let revision = dirtyPages[id], revision <= context.revision {
            dirtyPages.removeValue(forKey: id)
        }
    }
}

extension AppModel {
    func watchLaterReadContext() -> WatchLaterSynchronization.Context? {
        let owner = tabOwner ?? self
        guard let accountID = owner.profile?.id else { return nil }
        return owner.watchLaterSynchronization.prepare(
            accountID: accountID, generation: owner.accountGeneration)
    }

    func matchesWatchLaterAccount(_ context: WatchLaterSynchronization.Context) -> Bool {
        let owner = tabOwner ?? self
        return owner.profile?.id == context.accountID
            && owner.accountGeneration == context.accountGeneration
    }

    private var watchLaterPages: [AppModel] {
        [self] + Array(browseInstances.values) + Array(playbackInstances.values)
    }

    func publishWatchLaterBusy() {
        if let accountID = profile?.id {
            _ = watchLaterSynchronization.prepare(
                accountID: accountID, generation: accountGeneration)
        } else {
            watchLaterSynchronization.reset()
        }
        for page in watchLaterPages { page.libraryBusy = watchLaterSynchronization.busy }
    }

    func watchLaterDidChange(_ video: Video, remove: Bool) {
        let pages = watchLaterPages
        let lists = pages.filter {
            $0.menu == .watchLater && !$0.managesPlaybackTabs && $0.selected == nil
        }
        let index = lists.compactMap { $0.videos.firstIndex(where: { $0.id == video.id }) }.first
        let state = watchLaterSynchronization
        state.record(video, removed: remove, index: index)
        let key = BrowseDestination.watchLater.rawValue
        for page in pages {
            if let cached = page.cachedLists[key] {
                page.cachedLists[key] = state.applyLatest(video.id, to: cached)
            }
        }
        for page in lists {
            // An unattempted page still loads the complete library when opened.
            if page.browseLoadAttempted {
                page.videos = state.applyLatest(video.id, to: page.videos)
                page.cachedLists[key] = page.videos
                state.changed(page)
            }
            if remove {
                page.removedLater = video
            } else if page.removedLater?.id == video.id {
                page.removedLater = nil
            }
        }
    }
}
