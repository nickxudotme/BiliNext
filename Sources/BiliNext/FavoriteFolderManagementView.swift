import BiliNextCore
import SwiftUI

struct FavoriteFolderEditorRequest: Identifiable {
    let id = UUID()
    let accountID: Int64
    var folder: FavoriteFolder? = nil
}

/// A native folder list. Writes only begin from the editor or the confirmed delete button.
struct FavoriteFolderManagementView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteFolder] = []
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?
    @State private var refresh = UUID()
    @State private var editor: FavoriteFolderEditorRequest?
    @State private var deleting: FavoriteFolder?
    @State private var confirmingDelete = false
    @State private var mutation: Task<Void, Never>?
    @State private var pendingChange: FolderChange?

    private struct FolderChange {
        let accountID: Int64
        var preferredID: Int64? = nil
        var deletedID: Int64? = nil
        let notice: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("管理收藏夹").font(GlassTheme.readingFont.weight(.semibold))
                if loading || busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("新建收藏夹", systemImage: "folder.badge.plus") {
                    guard let accountID = model.profile?.id else { return }
                    editor = FavoriteFolderEditorRequest(accountID: accountID)
                }
                .disabled(busy || loading || pendingChange != nil || model.profile == nil)
            }
            if let notice {
                Text(notice).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
            }
            if let error {
                ErrorBanner(message: error) { refresh = UUID() }
            }
            if folders.isEmpty {
                if !loading && error == nil {
                    ContentUnavailableView(
                        "还没有收藏夹", systemImage: "folder",
                        description: Text("新建收藏夹，整理收藏的视频。"))
                } else {
                    Spacer(minLength: 0)
                }
            } else {
                List(folders) { folder in folderRow(folder) }
                    .listStyle(.inset)
                    .clipShape(RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
            }
            HStack {
                Button("刷新列表") { refresh = UUID() }.disabled(loading || busy)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            .controlSize(.large).font(GlassTheme.labelFont)
        }
        .padding(24).frame(width: 500, height: 460)
        .interactiveDismissDisabled(busy)
        .task(id: "\(model.profile?.id ?? 0):\(refresh)") { await load() }
        .onChange(of: model.profile?.id) { _, _ in
            mutation?.cancel()
            busy = false
            folders = []
            pendingChange = nil
            notice = nil
            editor = nil
            deleting = nil
            confirmingDelete = false
        }
        .onDisappear { mutation?.cancel() }
        .sheet(item: $editor) { request in
            FavoriteFolderEditorView(model: model, request: request) { id in
                pendingChange = FolderChange(
                    accountID: request.accountID,
                    preferredID: request.folder == nil ? id : nil,
                    notice: request.folder == nil ? "收藏夹已创建" : "收藏夹已重命名")
                notice = pendingChange?.notice
                refresh = UUID()
            }
        }
        .alert("删除收藏夹？", isPresented: $confirmingDelete, presenting: deleting) { folder in
            Button("删除收藏夹", role: .destructive) { delete(folder) }
            Button("取消", role: .cancel) { deleting = nil }
        } message: { folder in
            Text("将删除「\(folder.title)」及其中的收藏记录。此操作无法撤销。")
        }
    }

    private func folderRow(_ folder: FavoriteFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: folder.privacy == 1 ? "lock.rectangle" : "folder")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(folder.title).font(GlassTheme.bodyFont).lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(folder.count) 个内容")
                    if folder.isDefault { Text("默认收藏夹") }
                    if let privacy = folder.privacy { Text(privacy == 1 ? "私密" : "公开") }
                }
                .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("管理 \(folder.title)", systemImage: "ellipsis") {
                Button("重命名") {
                    guard let accountID = model.profile?.id else { return }
                    editor = FavoriteFolderEditorRequest(accountID: accountID, folder: folder)
                }
                .disabled(folder.isDefault)
                Button("删除收藏夹…", role: .destructive) {
                    deleting = folder
                    confirmingDelete = true
                }
                .disabled(folder.isDefault)
            }
            .labelStyle(.iconOnly).menuIndicator(.hidden)
            .disabled(loading || busy || pendingChange != nil || model.profile == nil)
            .help(folder.isDefault ? "默认收藏夹不能重命名或删除" : "管理收藏夹")
        }
        .padding(.vertical, 5)
    }

    private func load() async {
        guard let accountID = model.profile?.id else {
            loading = false
            error = "请先登录后管理收藏夹"
            return
        }
        let change = pendingChange
        loading = true
        error = nil
        do {
            let result = try await model.api.favoriteFolders(mid: accountID)
            guard !Task.isCancelled, model.profile?.id == accountID else { return }
            if let change, change.accountID == accountID,
                change.preferredID.map { id in !result.contains { $0.id == id } } == true
                    || change.deletedID.map { id in result.contains { $0.id == id } } == true
            {
                error = "\(change.notice)，列表尚未更新，请重试读取"
                loading = false
                return
            }
            folders = result
            model.favoriteFoldersDidChange(
                result, accountID: accountID,
                preferredFolderID: change?.accountID == accountID ? change?.preferredID : nil,
                deletedFolderID: change?.accountID == accountID ? change?.deletedID : nil)
            pendingChange = nil
        } catch {
            guard !Task.isCancelled, model.profile?.id == accountID else { return }
            if let change, change.accountID == accountID {
                self.error = "\(change.notice)，但列表更新失败：\(error.localizedDescription)"
            } else {
                self.error = error.localizedDescription
            }
        }
        if !Task.isCancelled, model.profile?.id == accountID { loading = false }
    }

    private func delete(_ folder: FavoriteFolder) {
        guard !busy, !folder.isDefault, let accountID = model.profile?.id else { return }
        busy = true
        error = nil
        mutation = Task {
            do {
                try await model.api.deleteFavoriteFolder(id: folder.id, expectedUserID: accountID)
                guard !Task.isCancelled, model.profile?.id == accountID else { return }
                busy = false
                folders.removeAll { $0.id == folder.id }
                model.favoriteFoldersDidChange(
                    folders, accountID: accountID, deletedFolderID: folder.id)
                pendingChange = FolderChange(
                    accountID: accountID, deletedID: folder.id, notice: "收藏夹已删除")
                notice = pendingChange?.notice
                deleting = nil
                refresh = UUID()
            } catch {
                guard !Task.isCancelled, model.profile?.id == accountID else { return }
                self.error = error.localizedDescription
                busy = false
            }
        }
    }
}

/// Used both by folder management and the favorite picker; it never saves video membership.
struct FavoriteFolderEditorView: View {
    @ObservedObject var model: AppModel
    let request: FavoriteFolderEditorRequest
    let onSaved: (Int64?) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @State private var title: String
    @State private var isPublic = false
    @State private var saving = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?

    init(
        model: AppModel, request: FavoriteFolderEditorRequest, onSaved: @escaping (Int64?) -> Void
    ) {
        self.model = model
        self.request = request
        self.onSaved = onSaved
        _title = State(initialValue: request.folder?.title ?? "")
    }

    private var creating: Bool { request.folder == nil }
    private var sameAccount: Bool { model.profile?.id == request.accountID }
    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(creating ? "新建收藏夹" : "重命名收藏夹")
                .font(GlassTheme.readingFont.weight(.semibold))
            Form {
                TextField("名称", text: $title).focused($nameFocused)
                    .onSubmit(submit)
                if creating {
                    Toggle("公开收藏夹", isOn: $isPublic)
                    Text("私密收藏夹仅自己可见。")
                        .font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                }
            }
            .disabled(saving || !sameAccount)
            if let error {
                Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(creating ? "创建" : "保存", action: submit)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(saving || !sameAccount || trimmedTitle.isEmpty)
            }
            .controlSize(.large).font(GlassTheme.labelFont)
        }
        .padding(24).frame(width: 380)
        .interactiveDismissDisabled(saving)
        .onAppear {
            nameFocused = true
            if !sameAccount { error = "账号已变更，请关闭后重新打开" }
        }
        .onChange(of: model.profile?.id) { _, _ in
            operation?.cancel()
            saving = false
            error = "账号已变更，请关闭后重新打开"
        }
        .onDisappear { operation?.cancel() }
    }

    private func submit() {
        guard !saving, sameAccount, !trimmedTitle.isEmpty else { return }
        saving = true
        error = nil
        let name = trimmedTitle
        operation = Task {
            do {
                let id: Int64
                if let folder = request.folder {
                    try await model.api.renameFavoriteFolder(
                        id: folder.id, title: name, expectedUserID: request.accountID)
                    id = folder.id
                } else {
                    let folder = try await model.api.createFavoriteFolder(
                        title: name, privacy: isPublic ? 0 : 1, expectedUserID: request.accountID)
                    id = folder.id
                }
                guard !Task.isCancelled, sameAccount else { return }
                onSaved(id)
                dismiss()
            } catch FavoriteFolderMutationError.createdWithoutIdentifier {
                guard !Task.isCancelled, sameAccount else { return }
                onSaved(nil)
                dismiss()
            } catch {
                guard !Task.isCancelled, sameAccount else { return }
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
