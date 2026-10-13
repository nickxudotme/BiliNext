import Foundation
import Security

public enum CredentialStorage: Sendable {
    case keychain
    #if DEBUG
        case developmentFile
    #endif
}

// A separate ephemeral cookie jar keeps the app session separate from browsers.
public actor BilibiliAPI {
    private let session: URLSession
    public func officialPlayerCookies() -> [HTTPCookie] {
        (cookieJar.cookies ?? []).filter {
            $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")
        }
    }
    private let cookieJar: HTTPCookieStorage
    private static let service = "me.nickxu.BiliNext.session"
    private var signingKey: (value: String, date: Date)?
    private let credentialStorage: CredentialStorage
    public init(restoreSession: Bool = true, credentialStorage: CredentialStorage = .keychain) {
        self.credentialStorage = credentialStorage
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0", "Referer": "https://www.bilibili.com/",
        ]
        cookieJar = config.httpCookieStorage!
        session = URLSession(configuration: config)
        var saved: Data?
        if restoreSession {
            switch credentialStorage {
            case .keychain: saved = Self.readCredential()
            #if DEBUG
                case .developmentFile:
                    saved = try? DevelopmentSessionStore.current.read()
                    if saved == nil {
                        // One-way migration must never display an authorization dialog.
                        saved = Self.readCredential(silent: true)
                        try? DevelopmentSessionStore.current.write(saved ?? Data("[]".utf8))
                    }
            #endif
            }
        }
        if let data = saved,
            let records = try? JSONDecoder().decode([CookieRecord].self, from: data)
        {
            for record in records { if let cookie = record.cookie { cookieJar.setCookie(cookie) } }
        }
    }
    private struct CookieRecord: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var expires: Date?
        init(_ c: HTTPCookie) {
            name = c.name
            value = c.value
            domain = c.domain
            path = c.path
            expires = c.expiresDate
        }
        var cookie: HTTPCookie? {
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE",
            ]
            if let expires { properties[.expires] = expires }
            return HTTPCookie(properties: properties)
        }
    }
    private static var keyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "default",
        ]
    }
    private static func readCredential(silent: Bool = false) -> Data? {
        var previousInteraction = DarwinBoolean(true)
        if silent {
            guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
            else { return nil }
        }
        defer { if silent { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
        var q = keyQuery
        q[kSecReturnData as String] = true
        if silent { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    private func saveCredential() throws {
        let records = (cookieJar.cookies ?? []).filter {
            $0.domain == "bilibili.com" || $0.domain.hasSuffix(".bilibili.com")
        }.map(CookieRecord.init)
        let data = try JSONEncoder().encode(records)
        #if DEBUG
            if case .developmentFile = credentialStorage {
                try DevelopmentSessionStore.current.write(data)
                return
            }
        #endif
        var add = Self.keyQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        let result =
            status == errSecDuplicateItem
            ? SecItemUpdate(
                Self.keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            : status
        guard result == errSecSuccess else {
            throw APIError(code: Int(result), message: "无法将登录状态保存到钥匙串")
        }
    }
    public func logout() throws {
        #if DEBUG
            if case .developmentFile = credentialStorage {
                try DevelopmentSessionStore.current.clear()
                for cookie in cookieJar.cookies ?? [] { cookieJar.deleteCookie(cookie) }
                signingKey = nil
                return
            }
        #endif
        let status = SecItemDelete(Self.keyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIError(code: Int(status), message: "无法清除钥匙串登录状态")
        }
        for cookie in cookieJar.cookies ?? [] { cookieJar.deleteCookie(cookie) }
    }
    func request(
        _ path: String, params: [String: String] = [:], passport: Bool = false,
        signed: Bool = false, allowGuestNav: Bool = false, form: [String: String]? = nil,
        expectedUserID: Int64? = nil, live: Bool = false
    ) async throws -> [String: Any] {
        var parameters = params
        if signed {
            if signingKey == nil || Date().timeIntervalSince(signingKey!.date) > 14400 {
                let nav = try await request("/x/web-interface/nav", allowGuestNav: true)
                let images = nav["wbi_img"] as? [String: Any] ?? [:]
                func key(_ name: String) -> String {
                    URL(string: images[name] as? String ?? "")?.deletingPathExtension()
                        .lastPathComponent ?? ""
                }
                signingKey = (
                    try WBISigner.mixinKey(image: key("img_url"), sub: key("sub_url")), Date()
                )
            }
            parameters = WBISigner.sign(
                params, key: signingKey!.value, timestamp: Int(Date().timeIntervalSince1970))
        }
        var u = URLComponents(
            string: "https://\(live ? "api.live" : (passport ? "passport" : "api")).bilibili.com"
                + path)!
        u.percentEncodedQuery = WBISigner.query(parameters)
        var req = URLRequest(url: u.url!)
        if live { req.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer") }
        if let expectedUserID {
            guard let value = cookieJar.cookies?.first(where: { $0.name == "DedeUserID" })?.value,
                Int64(value) == expectedUserID
            else { throw APIError(code: -101, message: "历史记录的账号已变化") }
            // Bind this request to a cookie snapshot before the first suspension point.
            req.httpShouldHandleCookies = false
            let cookies = cookieJar.cookies(for: u.url!) ?? []
            for (key, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                req.setValue(value, forHTTPHeaderField: key)
            }
        }
        if var form {
            guard let csrf = cookieJar.cookies?.first(where: { $0.name == "bili_jct" })?.value,
                !csrf.isEmpty
            else { throw APIError(code: -101, message: "请先登录") }
            form["csrf"] = csrf
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(WBISigner.query(form).utf8)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(code: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "请求失败")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError(code: -1, message: "返回格式不正确")
        }
        let code = (root["code"] as? NSNumber)?.intValue ?? -1
        guard code == 0 || (allowGuestNav && code == -101) else {
            throw APIError(code: code, message: root["message"] as? String ?? "接口请求失败")
        }
        return root["data"] as? [String: Any] ?? root["result"] as? [String: Any] ?? [
            "_array": root["data"] as? [[String: Any]] ?? []
        ]
    }
    func liveDanmakuIdentity() -> (userID: Int64, buvid: String) {
        let cookies = cookieJar.cookies ?? []
        return (
            Int64(cookies.first { $0.name == "DedeUserID" }?.value ?? "") ?? 0,
            cookies.first { $0.name == "buvid3" }?.value ?? ""
        )
    }

    public func makeLiveDanmakuSocket(
        _ configuration: LiveDanmakuConfiguration, endpoint: URL? = nil
    )
        -> URLSessionWebSocketTask
    {
        var request = URLRequest(
            url: endpoint.flatMap { configuration.endpoints.contains($0) ? $0 : nil }
                ?? configuration.endpoint)
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Origin")
        request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
        return session.webSocketTask(with: request)
    }

    func requestArray(_ path: String, params: [String: String]) async throws -> [[String: Any]] {
        let result = try await request(path, params: params)
        return result["_array"] as? [[String: Any]] ?? []
    }
    public func profile() async throws -> UserProfile {
        let d = try await request("/x/web-interface/nav")
        guard d["isLogin"] as? Bool == true else { throw APIError(code: -101, message: "尚未登录") }
        return UserProfile(
            id: (d["mid"] as? NSNumber)?.int64Value ?? 0, name: d["uname"] as? String ?? "已登录")
    }
    public func loginCode() async throws -> LoginCode {
        let d = try await request("/x/passport-login/web/qrcode/generate", passport: true)
        guard let url = d["url"] as? String, let key = d["qrcode_key"] as? String else {
            throw APIError(code: -1, message: "二维码生成失败")
        }
        return LoginCode(url: url, key: key)
    }
    public func pollLogin(_ key: String) async throws -> LoginStatus {
        let d = try await request(
            "/x/passport-login/web/qrcode/poll", params: ["qrcode_key": key], passport: true)
        switch (d["code"] as? NSNumber)?.intValue {
        case 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            // Some responses carry the session in the callback query rather than
            // Set-Cookie. Accept only the known session fields, never follow it.
            if let value = d["url"] as? String, let url = URLComponents(string: value) {
                for item in url.queryItems ?? []
                where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(
                    item.name)
                {
                    if let value = item.value,
                        let cookie = HTTPCookie(properties: [
                            .name: item.name, .value: value, .domain: ".bilibili.com", .path: "/",
                            .secure: "TRUE",
                        ])
                    {
                        cookieJar.setCookie(cookie)
                    }
                }
            }
            try saveCredential()
            return .success
        default:
            throw APIError(code: (d["code"] as? NSNumber)?.intValue ?? -1, message: "登录状态异常，请刷新二维码")
        }
    }
    func video(_ d: [String: Any]) -> Video? {
        guard let bvid = d["bvid"] as? String, !bvid.isEmpty else { return nil }
        let owner = d["owner"] as? [String: Any] ?? [:]
        let stat = d["stat"] as? [String: Any] ?? [:]
        func count(_ value: Any?) -> String? {
            if let value = value as? NSNumber { return value.stringValue }
            return value as? String
        }
        let duration =
            (d["duration"] as? NSNumber)?.doubleValue
            ?? (d["duration"] as? String ?? d["duration_text"] as? String).flatMap {
                text -> Double? in
                let parts = text.split(separator: ":").compactMap { Double($0) }
                guard !parts.isEmpty, parts.count == text.split(separator: ":").count else {
                    return nil
                }
                return parts.reduce(0) { $0 * 60 + $1 }
            }
        let title = (d["title"] as? String ?? "未命名视频").replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression
        ).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(
            of: "&quot;", with: "\"")
        return Video(
            bvid: bvid, title: title,
            author: owner["name"] as? String ?? d["author"] as? String ?? "",
            cover: secureURL(d["pic"] as? String ?? d["cover"] as? String ?? ""),
            avatar: secureURL(owner["face"] as? String ?? ""),
            aid: (d["aid"] as? NSNumber)?.int64Value,
            duration: duration,
            ownerID: (owner["mid"] as? NSNumber)?.int64Value ?? (d["mid"] as? NSNumber)?.int64Value,
            viewCount: count(stat["view"] ?? stat["play"] ?? d["play"] ?? d["view"]),
            danmakuCount: count(stat["danmaku"] ?? d["video_review"] ?? d["danmaku"]),
            pubdate: DisplayFormat.date(fromUnix: d["pubdate"] ?? d["ctime"]))
    }
    public func popular(page: Int = 1) async throws -> [Video] {
        let d = try await request(
            "/x/web-interface/popular", params: ["pn": "\(page)", "ps": "20"])
        return (d["list"] as? [[String: Any]] ?? []).compactMap(video)
    }
    public func search(_ keyword: String, page: Int = 1, order: String = "totalrank") async throws
        -> [Video]
    {
        // Acquire the public browser identifier before search; this does not
        // bypass risk controls. 412 is surfaced to the user without retry loops.
        if !(cookieJar.cookies ?? []).contains(where: { $0.name == "buvid3" }) {
            let identifiers = try await request("/x/frontend/finger/spi")
            if let id = identifiers["b_3"] as? String,
                let c = HTTPCookie(properties: [
                    .name: "buvid3", .value: id, .domain: ".bilibili.com", .path: "/",
                    .secure: "TRUE",
                ])
            {
                cookieJar.setCookie(c)
            }
        }
        let d = try await request(
            "/x/web-interface/wbi/search/type",
            params: [
                "search_type": "video", "keyword": keyword, "page": "\(page)", "order": order,
            ], signed: true)
        return (d["result"] as? [[String: Any]] ?? []).compactMap(video)
    }
    public func feed(offset: String? = nil) async throws -> Feed {
        var params = ["type": "video", "timezone_offset": "-480", "features": "itemOpusStyle"]
        if let offset { params["offset"] = offset }
        let d = try await request("/x/polymer/web-dynamic/v1/feed/all", params: params)
        let videos: [Video] = (d["items"] as? [[String: Any]] ?? []).compactMap { item in
            let modules = item["modules"] as? [String: Any] ?? [:]
            let author = modules["module_author"] as? [String: Any] ?? [:]
            let dynamic = modules["module_dynamic"] as? [String: Any] ?? [:]
            let major = dynamic["major"] as? [String: Any] ?? [:]
            guard var archive = major["archive"] as? [String: Any] else { return nil }
            archive["owner"] = ["name": author["name"] ?? "", "face": author["face"] ?? ""]
            archive["pubdate"] = author["pub_ts"]
            return video(archive)
        }
        return Feed(
            videos: videos, next: (d["has_more"] as? Bool == true) ? d["offset"] as? String : nil)
    }
    public func detail(_ bvid: String) async throws -> VideoDetail {
        let d = try await request("/x/web-interface/view", params: ["bvid": bvid])
        guard let v = video(d) else { throw APIError(code: -1, message: "没有找到视频") }
        let pages = (d["pages"] as? [[String: Any]] ?? []).compactMap { p -> VideoPage? in
            guard let cid = (p["cid"] as? NSNumber)?.int64Value else { return nil }
            return VideoPage(
                cid: cid, number: (p["page"] as? NSNumber)?.intValue ?? 1,
                title: p["part"] as? String ?? "")
        }
        return VideoDetail(video: v, pages: pages, description: d["desc"] as? String ?? "")
    }
    public func playback(
        bvid: String, cid: Int64, quality: Int = 80, episodeID: Int64? = nil,
        preferDASH: Bool = true, allowAV1: Bool = true, allowHEVC: Bool = true
    )
        async throws -> Playback
    {
        var params = [
            "bvid": bvid, "cid": "\(cid)", "qn": String(quality),
            "fnval": preferDASH ? "4048" : "1",
            "fnver": "0", "fourk": "1",
        ]
        if !preferDASH {
            params["platform"] = "html5"
            params["high_quality"] = "1"
        }
        if let episodeID { params["ep_id"] = String(episodeID) }
        let d = try await request(
            episodeID == nil ? "/x/player/wbi/playurl" : "/pgc/player/web/playurl", params: params,
            signed: episodeID == nil)
        do {
            return try PlaybackParser.parse(
                d, preferredQuality: quality,
                allowAV1: allowAV1 && MediaCapabilities.hardwareAV1, allowHEVC: allowHEVC)
        } catch {
            try Task.checkCancellation()
            guard preferDASH else { throw error }
            // A response without compatible indexed streams may still offer a complete MP4.
            // API/permission errors above are surfaced directly, never retried here.
            return try await playback(
                bvid: bvid, cid: cid, quality: quality, episodeID: episodeID, preferDASH: false,
                allowAV1: allowAV1, allowHEVC: allowHEVC)
        }
    }
    public func subtitleTracks(bvid: String, cid: Int64) async throws -> [SubtitleTrack] {
        let d = try await request(
            "/x/player/wbi/v2", params: ["bvid": bvid, "cid": "\(cid)"], signed: true)
        let subtitle = d["subtitle"] as? [String: Any] ?? [:]
        return (subtitle["subtitles"] as? [[String: Any]] ?? []).compactMap {
            guard let url = secureURL($0["subtitle_url"] as? String ?? "") else { return nil }
            return SubtitleTrack(language: $0["lan_doc"] as? String ?? "字幕", url: url)
        }
    }
    public func subtitles(_ track: SubtitleTrack) async throws -> [Cue] {
        guard let host = track.url.host,
            host == "hdslb.com" || host.hasSuffix(".hdslb.com") || host == "bilibili.com"
                || host.hasSuffix(".bilibili.com")
        else { throw APIError(code: -1, message: "字幕来源域名不受支持") }
        let (data, response) = try await session.data(from: track.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(code: -1, message: "字幕下载失败")
        }
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (root["body"] as? [[String: Any]] ?? []).enumerated().compactMap { i, d in
            guard let start = d["from"] as? Double, let end = d["to"] as? Double,
                let text = d["content"] as? String, start.isFinite, end.isFinite, start >= 0,
                end >= start
            else { return nil }
            return Cue(id: i, start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }

    public func favoriteFolders(mid: Int64) async throws -> [FavoriteFolder] {
        let data = try await request(
            "/x/v3/fav/folder/created/list-all", params: ["up_mid": String(mid)])
        return (data["list"] as? [[String: Any]] ?? []).compactMap {
            guard let id = ($0["id"] as? NSNumber)?.int64Value else { return nil }
            return FavoriteFolder(
                id: id, title: $0["title"] as? String ?? "收藏夹",
                count: ($0["media_count"] as? NSNumber)?.intValue ?? 0)
        }
    }
    public func favorites(folder: Int64, page: Int, keyword: String = "", order: String = "mtime")
        async throws -> Feed
    {
        let data = try await request(
            "/x/v3/fav/resource/list",
            params: [
                "media_id": String(folder), "pn": String(page), "ps": "20", "order": order,
                "keyword": keyword, "platform": "web",
            ])
        return LibraryParser.favorites(data, page: page)
    }
    public func watchLater(page: Int) async throws -> Feed {
        let data = try await request(
            "/x/v2/history/toview/web",
            params: [
                "pn": String(page), "ps": "20", "viewed": "0", "asc": "false", "need_split": "true",
                "web_location": "333.881",
            ], signed: true)
        return LibraryParser.watchLater(data, page: page)
    }
    public func watchHistory(cursor: String?) async throws -> Feed {
        var params = [
            "type": "archive", "ps": "20", "max": "0", "view_at": "0", "business": "archive",
        ]
        if let cursor, let data = cursor.data(using: .utf8),
            let values = try? JSONDecoder().decode([String: String].self, from: data)
        {
            for key in ["max", "view_at", "business"] {
                if let value = values[key] { params[key] = value }
            }
        }
        let data = try await request("/x/web-interface/history/cursor", params: params)
        return LibraryParser.history(data, previousCursor: cursor)
    }
    public func reportWatchProgress(
        bvid: String, cid: Int64, position: Double, expectedUserID: Int64? = nil
    ) async throws {
        guard position.isFinite, position >= 0, cid > 0 else { return }
        _ = try await request(
            "/x/click-interface/web/heartbeat",
            form: [
                "bvid": bvid, "cid": String(cid),
                "played_time": String(Int(min(position, Double(Int32.max)))),
                "type": "3", "dt": "2", "play_type": "0",
            ], expectedUserID: expectedUserID)
    }
    public func searchHistory(keyword: String, page: Int) async throws -> Feed {
        let data = try await request(
            "/x/web-interface/history/search",
            params: ["pn": String(page), "ps": "20", "keyword": keyword, "business": "archive"])
        let parsed = LibraryParser.history(data, previousCursor: nil)
        let count =
            (data["has_more"] as? Bool) ?? (!parsed.videos.isEmpty && parsed.videos.count >= 20)
        return Feed(videos: parsed.videos, next: count ? String(page + 1) : nil)
    }
    public func addToWatchLater(bvid: String) async throws {
        _ = try await request("/x/v2/history/toview/add", form: ["bvid": bvid])
    }
    public func removeFromWatchLater(aid: Int64) async throws {
        _ = try await request("/x/v2/history/toview/v2/dels", form: ["resources": String(aid)])
    }
    public func danmaku(cid: Int64, segment: Int) async throws -> [Danmaku] {
        var url = URLComponents(string: "https://api.bilibili.com/x/v2/dm/web/seg.so")!
        url.queryItems = [
            URLQueryItem(name: "type", value: "1"), URLQueryItem(name: "oid", value: String(cid)),
            URLQueryItem(name: "segment_index", value: String(max(1, segment))),
        ]
        let (data, response) = try await session.data(from: url.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError(
                code: (response as? HTTPURLResponse)?.statusCode ?? -1, message: "弹幕加载失败")
        }
        return try DanmakuDecoder.decode(data)
    }

    /// Public, credential-free curve the official player loads beside the progress bar.
    public func highEnergy(aid: Int64?, bvid: String, cid: Int64) async throws -> HighEnergyCurve? {
        var url = URLComponents(string: "https://bvc.bilivideo.com/pbp/data")!
        url.queryItems =
            [
                URLQueryItem(name: "bvid", value: bvid),
                URLQueryItem(name: "cid", value: String(cid)),
                URLQueryItem(name: "r", value: "loader"),
            ] + (aid.map { [URLQueryItem(name: "aid", value: String($0))] } ?? [])
        var request = URLRequest(url: url.url!)
        request.httpShouldHandleCookies = false
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return HighEnergyCurve.parse(body)
    }

}
