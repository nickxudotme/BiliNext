import Foundation

public enum FavoriteFolderMutationError: LocalizedError, Sendable {
    /// The write succeeded; callers must refresh the list rather than offer another create POST.
    case createdWithoutIdentifier

    public var errorDescription: String? {
        "收藏夹已新建，请刷新列表确认"
    }
}

extension BilibiliAPI {
    static func parseFavoriteFolder(_ data: [String: Any]) -> FavoriteFolder? {
        func integer(_ value: Any?) -> Int64? {
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let integer = number.int64Value
                return number == NSNumber(value: integer) ? integer : nil
            }
            return (value as? String).flatMap(Int64.init)
        }
        guard let id = integer(data["id"]), id > 0 else { return nil }
        let attr = integer(data["attr"]).flatMap { $0 >= 0 ? Int(exactly: $0) : nil }
        let upper = data["upper"] as? [String: Any] ?? [:]
        return FavoriteFolder(
            id: id, title: data["title"] as? String ?? "收藏夹",
            count: integer(data["media_count"]).flatMap(Int.init(exactly:)) ?? 0,
            attr: attr, ownerID: integer(data["mid"] ?? upper["mid"]),
            intro: data["intro"] as? String, cover: data["cover"] as? String)
    }

    /// New folders are private unless the user explicitly chooses privacy = 0 (public).
    public func createFavoriteFolder(
        title: String, privacy: Int = 1, expectedUserID: Int64
    ) async throws -> FavoriteFolder {
        try Self.validateFavoriteTitle(title)
        guard privacy == 0 || privacy == 1, expectedUserID > 0 else {
            throw APIError(code: -1, message: "收藏夹隐私或账号参数无效")
        }
        let data = try await request(
            "/x/v3/fav/folder/add",
            form: ["title": title, "intro": "", "privacy": String(privacy), "cover": ""],
            expectedUserID: expectedUserID)
        guard let folder = Self.parseFavoriteFolder(data) else {
            throw FavoriteFolderMutationError.createdWithoutIdentifier
        }
        return FavoriteFolder(
            id: folder.id, title: data["title"] as? String ?? title, count: folder.count,
            attr: folder.attr ?? (2 | privacy), ownerID: folder.ownerID ?? expectedUserID,
            intro: folder.intro ?? "", cover: folder.cover ?? "")
    }

    /// Fetches the complete metadata first, so renaming never resets a sparse list row's fields.
    public func renameFavoriteFolder(
        id: Int64, title: String, expectedUserID: Int64
    ) async throws {
        try Self.validateFavoriteTitle(title)
        let folder = try await editableFavoriteFolder(id: id, expectedUserID: expectedUserID)
        guard let intro = folder.intro, let cover = folder.cover, let privacy = folder.privacy
        else {
            throw APIError(code: -1, message: "收藏夹信息不完整，请刷新后重试")
        }
        _ = try await request(
            "/x/v3/fav/folder/edit",
            form: [
                "media_id": String(id), "title": title, "intro": intro,
                "privacy": String(privacy), "cover": cover,
            ], expectedUserID: expectedUserID)
    }

    public func deleteFavoriteFolder(id: Int64, expectedUserID: Int64) async throws {
        _ = try await editableFavoriteFolder(id: id, expectedUserID: expectedUserID)
        _ = try await request(
            "/x/v3/fav/folder/del", form: ["media_ids": String(id)],
            expectedUserID: expectedUserID)
    }

    private func editableFavoriteFolder(id: Int64, expectedUserID: Int64) async throws
        -> FavoriteFolder
    {
        guard id > 0, expectedUserID > 0 else {
            throw APIError(code: -1, message: "收藏夹或账号参数无效")
        }
        let data = try await request(
            "/x/v3/fav/folder/info", params: ["media_id": String(id)],
            expectedUserID: expectedUserID)
        guard let folder = Self.parseFavoriteFolder(data), folder.id == id, folder.attr != nil,
            let owner = folder.ownerID
        else { throw APIError(code: -1, message: "收藏夹信息不完整，请刷新后重试") }
        guard owner == expectedUserID else {
            throw APIError(code: -403, message: "只能管理当前账号创建的收藏夹")
        }
        guard !folder.isDefault else {
            throw APIError(code: -1, message: "默认收藏夹不能重命名或删除")
        }
        return folder
    }

    private static func validateFavoriteTitle(_ title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(code: -1, message: "请输入收藏夹名称")
        }
    }
}
