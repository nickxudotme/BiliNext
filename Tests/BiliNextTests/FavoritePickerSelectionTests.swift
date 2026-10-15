import Testing

@testable import BiliNext
@testable import BiliNextCore

@Test func newlyCreatedFolderPreservesThePickersUnsavedAddsAndRemovals() {
    let folders = [
        FavoriteSelection(id: 1, title: "已取消", selected: true),
        FavoriteSelection(id: 2, title: "刚勾选", selected: false),
        FavoriteSelection(id: 3, title: "新建", selected: false),
    ]
    let selected = FavoritePickerView.selectionAfterReload(
        folders, original: [1], selected: [2], createdFolderID: 3)
    #expect(selected == [2, 3])
}

@Test func pickerReloadIncludesRemoteChangesOutsideTheUsersUnsavedDifference() {
    let folders = [
        FavoriteSelection(id: 1, title: "原来已收藏", selected: true),
        FavoriteSelection(id: 2, title: "其他设备新收藏", selected: true),
        FavoriteSelection(id: 3, title: "本地刚勾选", selected: false),
    ]
    let selected = FavoritePickerView.selectionAfterReload(
        folders, original: [1], selected: [1, 3], createdFolderID: nil)
    #expect(selected == [1, 2, 3])
}

@Test func pickerReloadDropsDeletedFoldersWithoutInventingAnUnknownCreatedFolder() {
    let folders = [FavoriteSelection(id: 1, title: "仍存在", selected: true)]
    let selected = FavoritePickerView.selectionAfterReload(
        folders, original: [1, 2], selected: [1, 2, 3], createdFolderID: nil)
    #expect(selected == [1])
}
