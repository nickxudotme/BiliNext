#if DEBUG
    import Foundation

    // Development only. The parent directory is private before any data is written.
    struct DevelopmentSessionStore {
        let directory: URL
        var file: URL { directory.appendingPathComponent("login-session.json") }
        static var current: Self {
            Self(
                directory: FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("BiliNext/Development", isDirectory: true))
        }
        func read() throws -> Data? {
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            try validate(directory, type: .typeDirectory)
            try validate(file, type: .typeRegular)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            return try Data(contentsOf: file)
        }
        func write(_ data: Data) throws {
            let manager = FileManager.default
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try validate(directory, type: .typeDirectory)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if manager.fileExists(atPath: file.path) { try validate(file, type: .typeRegular) }
            try data.write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        // Leave an empty record so logout cannot resurrect the old Keychain session.
        func clear() throws { try write(Data("[]".utf8)) }
        private func validate(_ url: URL, type: FileAttributeType) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == type else {
                throw APIError(code: -1, message: "开发版登录存储路径不是预期的文件类型")
            }
        }
    }
#endif
