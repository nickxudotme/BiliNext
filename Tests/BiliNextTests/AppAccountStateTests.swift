import Combine
import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func accountChangesReachEveryRetainedPageAndPublishToExistingObservers() {
    let owner = AppModel(api: BilibiliAPI(restoreSession: false))
    let browse = owner.browseInstance(for: .home)
    let player = owner.playbackInstance(for: SessionTab(video: Video(bvid: "offline", title: "测试")))
    let other = AppModel(api: BilibiliAPI(restoreSession: false))
    var changes = [0, 0, 0]
    let subscriptions = [owner, browse, player].enumerated().map { index, page in
        page.objectWillChange.sink { changes[index] += 1 }
    }
    owner.profile = UserProfile(id: 8, name: "测试账号")
    #expect([owner, browse, player].allSatisfy { $0.profile?.id == 8 })
    #expect(changes == [1, 1, 1])
    #expect(other.profile == nil)
    let generation = UUID()
    owner.accountGeneration = generation
    #expect([owner, browse, player].allSatisfy { $0.accountGeneration == generation })
    #expect(other.accountGeneration != generation)
    owner.profile = nil
    #expect([owner, browse, player].allSatisfy { $0.profile == nil })
    withExtendedLifetime(subscriptions) {}
}

@MainActor
@Test func creatingAndLookingUpPagesDoesNotRepublishTheSharedProfile() {
    let owner = AppModel(api: BilibiliAPI(restoreSession: false))
    owner.profile = UserProfile(id: 8, name: "测试账号")
    var publications = 0
    let subscription = owner.services.account.objectWillChange.sink { publications += 1 }
    let page = owner.browseInstance(for: .home)
    let tab = SessionTab(video: Video(bvid: "offline", title: "测试"))
    let player = owner.playbackInstance(for: tab)
    // Repeated lookup follows the same path used on tab activation without loading media.
    #expect(owner.playbackInstance(for: tab) === player)
    #expect(publications == 0)
    #expect(page.profile?.id == 8 && player.profile?.id == 8)
    withExtendedLifetime(subscription) {}
}

@MainActor
@Test func sharedAccountGenerationRejectsAnOldFolderResponse() async {
    var response: CheckedContinuation<[FavoriteFolder], Never>?
    let owner = AppModel(
        api: BilibiliAPI(restoreSession: false),
        favoriteFolderLoader: { _ in
            await withCheckedContinuation { response = $0 }
        })
    owner.profile = UserProfile(id: 8, name: "测试账号")
    let page = owner.browseInstance(for: .home)
    owner.preloadFavoriteFolders()
    let task = owner.favoriteFoldersTask
    while response == nil { await Task.yield() }
    owner.accountGeneration = UUID()
    owner.resetFavoriteFolderPreload()
    #expect(page.accountGeneration == owner.accountGeneration)
    response?.resume(returning: [FavoriteFolder(id: 42, title: "旧响应", count: 1)])
    await task?.value
    #expect(owner.folders.isEmpty && page.folders.isEmpty)
    #expect(!owner.favoriteFoldersLoading)
}
