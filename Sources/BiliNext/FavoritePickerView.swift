import BiliNextCore
import SwiftUI

struct FavoritePickerView: View {
    @ObservedObject var model: AppModel
    let aid: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteSelection] = []
    @State private var selected = Set<Int64>()
    @State private var original = Set<Int64>()
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false
    @State private var loadedAccountID: Int64?
    @State private var refresh = UUID()
    @State private var editor: FavoriteFolderEditorRequest?
    @State private var pendingFolderRefresh = false
    @State private var createdFolderID: Int64?
    @State private var notice: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("收藏到文件夹").font(GlassTheme.readingFont.weight(.semibold))
                Spacer()
                Button("新建收藏夹", systemImage: "folder.badge.plus") {
                    guard let accountID = model.profile?.id else { return }
                    editor = FavoriteFolderEditorRequest(accountID: accountID)
                }
                .labelStyle(.iconOnly).help("新建收藏夹")
                .disabled(loading || saving || pendingFolderRefresh || model.profile == nil)
            }
            if loading { ProgressView().controlSize(.small) }
            if let notice {
                Text(notice).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(folders) { folder in
                        Toggle(
                            folder.title,
                            isOn: Binding(
                                get: { selected.contains(folder.id) },
                                set: {
                                    if $0 {
                                        selected.insert(folder.id)
                                    } else {
                                        selected.remove(folder.id)
                                    }
                                })
                        )
                        .font(GlassTheme.bodyFont).frame(minHeight: GlassTheme.iconControlSize)
                    }
                }
            }
            .disabled(loading || saving || !loaded)
            if loaded && folders.isEmpty {
                Text("暂无收藏夹，点右上角新建。").font(GlassTheme.bodyFont).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if (!loaded || pendingFolderRefresh) && !loading {
                    Button("重试读取") { refresh = UUID() }.disabled(saving)
                }
                if saving { ProgressView().controlSize(.small) }
                Button("保存", action: save).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(loading || saving || !loaded || pendingFolderRefresh)
            }.controlSize(.large).font(GlassTheme.labelFont)
        }
        .padding(24).frame(width: 380, height: 380)
        .interactiveDismissDisabled(saving)
        .task(id: "\(model.profile?.id ?? 0):\(refresh)") { await load() }
        .onChange(of: model.profile?.id) { _, _ in
            saveTask?.cancel()
            saving = false
            folders = []
            original = []
            selected = []
            loaded = false
            loadedAccountID = nil
            pendingFolderRefresh = false
            createdFolderID = nil
            notice = nil
            editor = nil
        }
        .onDisappear { saveTask?.cancel() }
        .sheet(item: $editor) { request in
            FavoriteFolderEditorView(model: model, request: request) { id in
                guard model.profile?.id == request.accountID else { return }
                createdFolderID = id
                pendingFolderRefresh = true
                notice = id == nil ? "收藏夹已创建，请选择后保存" : "收藏夹已创建，点击保存完成收藏"
                refresh = UUID()
            }
        }
    }

    private func load() async {
        guard let accountID = model.profile?.id else {
            error = "请先登录"
            loading = false
            return
        }
        if loadedAccountID != accountID {
            folders = []
            original = []
            selected = []
            loaded = false
        }
        let previousOriginal = original
        let previousSelection = selected
        let pendingID = createdFolderID
        let folderWasCreated = pendingFolderRefresh
        loading = true
        error = nil
        do {
            async let allFolders = model.api.favoriteFolders(mid: accountID)
            async let choices = model.api.favoriteSelection(mid: accountID, aid: aid)
            let (fullList, result) = try await (allFolders, choices)
            guard !Task.isCancelled, model.profile?.id == accountID else { return }
            let available = Set(result.map(\.id))
            if let pendingID,
                !available.contains(pendingID) || !fullList.contains(where: { $0.id == pendingID })
            {
                error = "收藏夹已创建，列表尚未更新，请重试读取"
                loading = false
                return
            }
            let remote = Set(result.filter(\.selected).map(\.id))
            folders = result
            original = remote
            selected = Self.selectionAfterReload(
                result, original: previousOriginal, selected: previousSelection,
                createdFolderID: pendingID)
            loaded = true
            loadedAccountID = accountID
            pendingFolderRefresh = false
            createdFolderID = nil
            model.favoriteFoldersDidChange(fullList, accountID: accountID)
        } catch {
            guard !Task.isCancelled, model.profile?.id == accountID else { return }
            self.error =
                folderWasCreated
                ? "收藏夹已创建，但列表更新失败：\(error.localizedDescription)" : error.localizedDescription
        }
        if !Task.isCancelled, model.profile?.id == accountID { loading = false }
    }

    /// Preserve the user's unsaved toggles while incorporating the refreshed remote state.
    nonisolated static func selectionAfterReload(
        _ folders: [FavoriteSelection], original: Set<Int64>, selected: Set<Int64>,
        createdFolderID: Int64?
    ) -> Set<Int64> {
        let available = Set(folders.map(\.id))
        let remote = Set(folders.filter(\.selected).map(\.id))
        var result = remote.union(selected.subtracting(original))
            .subtracting(original.subtracting(selected)).intersection(available)
        if let createdFolderID, available.contains(createdFolderID) {
            result.insert(createdFolderID)
        }
        return result
    }

    private func save() {
        guard !saving, !loading, loaded, !pendingFolderRefresh, let accountID = model.profile?.id,
            loadedAccountID == accountID
        else { return }
        let before = original
        let after = selected
        saving = true
        error = nil
        saveTask = Task {
            do {
                try await model.api.saveFavorites(
                    aid: aid, add: after.subtracting(before), remove: before.subtracting(after),
                    expectedUserID: accountID)
                guard !Task.isCancelled, model.profile?.id == accountID else { return }
                model.favoriteMembershipDidChange(
                    aid: aid, before: before, after: after, accountID: accountID)
                dismiss()
            } catch {
                guard !Task.isCancelled, model.profile?.id == accountID else { return }
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
