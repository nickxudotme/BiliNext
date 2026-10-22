import Foundation
import Testing

@testable import BiliNext
@testable import BiliNextCore

@MainActor
@Test func startupPreloadsFoldersWithoutOpeningTheirVideos() async throws {
    var folderReads = 0
    var videoReads = 0
    let model = AppModel(
        sessionStore: SessionStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString)),
        api: BilibiliAPI(restoreSession: false),
        browsePageLoader: { _ in
            videoReads += 1
            return BrowsePageResult(videos: [], next: nil)
        },
        profileLoader: { UserProfile(id: 8, name: "离线测试") },
        favoriteFolderLoader: { mid in
            #expect(mid == 8)
            folderReads += 1
            return [FavoriteFolder(id: 42, title: "默认收藏夹", count: 12)]
        })
    model.selected = "existing-video"
    await model.start()
    await model.favoriteFoldersTask?.value
    #expect(model.folders.map(\.id) == [42])
    #expect(model.browseInstances.isEmpty && videoReads == 0)
    model.preloadFavoriteFolders()
    #expect(folderReads == 1 && model.favoriteFoldersTask == nil)
}

@MainActor
@Test func failedFolderPreloadCanRetryAndEmptySuccessIsCached() async {
    var reads = 0
    let model = AppModel(
        api: BilibiliAPI(restoreSession: false),
        favoriteFolderLoader: { _ in
            reads += 1
            if reads == 1 { throw URLError(.notConnectedToInternet) }
            return []
        })
    model.profile = UserProfile(id: 8, name: "离线测试")
    model.preloadFavoriteFolders()
    model.preloadFavoriteFolders()
    await model.favoriteFoldersTask?.value
    #expect(reads == 1 && model.favoriteFoldersError != nil && !model.favoriteFoldersLoading)
    model.preloadFavoriteFolders()
    await model.favoriteFoldersTask?.value
    model.preloadFavoriteFolders()
    #expect(reads == 2 && model.favoriteFoldersError == nil)
    #expect(model.favoriteFoldersAccountID == 8)
}

@MainActor
@Test func folderPreloadCannotOverwriteNewAccount() async {
    var response: CheckedContinuation<[FavoriteFolder], Never>?
    let model = AppModel(
        api: BilibiliAPI(restoreSession: false),
        favoriteFolderLoader: { _ in
            await withCheckedContinuation { response = $0 }
        })
    model.profile = UserProfile(id: 8, name: "旧账号")
    model.preloadFavoriteFolders()
    let oldTask = model.favoriteFoldersTask
    while response == nil { await Task.yield() }
    model.accountGeneration = UUID()
    model.resetFavoriteFolderPreload()
    model.profile = UserProfile(id: 9, name: "新账号")
    let current = [FavoriteFolder(id: 99, title: "新收藏夹", count: 1)]
    model.acceptFavoriteFolders(current)
    response?.resume(returning: [FavoriteFolder(id: 42, title: "旧收藏夹", count: 12)])
    await oldTask?.value
    #expect(model.folders == current && model.favoriteFoldersAccountID == 9)
}
