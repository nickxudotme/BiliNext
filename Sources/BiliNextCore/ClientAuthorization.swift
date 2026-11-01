import CryptoKit
import Foundation

/// Account-bound client credentials are stored alongside cookies, never in cookie headers.
struct ClientAuthorization: Codable, Sendable {
    let accountID: Int64
    let accessToken: String
    let expires: Date

    func isValid(accountID: Int64, now: Date = Date()) -> Bool {
        self.accountID == accountID && !accessToken.isEmpty && expires > now.addingTimeInterval(30)
    }

    static func parse(_ data: [String: Any], accountID: Int64, now: Date = Date()) throws -> Self {
        guard let token = data["token_info"] as? [String: Any],
            (token["mid"] as? NSNumber)?.int64Value == accountID, accountID > 0,
            let access = token["access_token"] as? String, !access.isEmpty,
            access.utf8.count <= 4096,
            let ttl = token["expires_in"] as? Int, ttl > 30, ttl <= 366 * 86400
        else { throw APIError(code: -1, message: "客户端授权不完整或账号不一致，保留原登录") }
        return Self(
            accountID: accountID, accessToken: access, expires: now.addingTimeInterval(Double(ttl)))
    }
}

enum ClientProtocol {
    // Public Android HD protocol identifiers; these are not account secrets.
    static func signed(_ values: [String: String], now: Date = Date()) -> [String: String] {
        var values = values
        values.removeValue(forKey: "sign")
        values["appkey"] = "dfca71928277209b"
        values["ts"] = String(Int(now.timeIntervalSince1970))
        let input = WBISigner.query(values) + "b5475a8825547a4fc26c7d518eaaa02e"
        values["sign"] = Insecure.MD5.hash(data: Data(input.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        return values
    }
}

extension BilibiliAPI {
    func clientRequest(_ path: String, form: [String: String], writing: Bool = false) async throws
        -> [String: Any]
    {
        let host: String
        switch path {
        case "/x/passport-tv-login/qrcode/auth_code", "/x/passport-tv-login/qrcode/poll":
            host = "passport.bilibili.com"
        case "/x/v2/view/coin/add", "/x/v2/view/like/triple": host = "app.bilibili.com"
        default: throw APIError(code: -1, message: "不支持的客户端请求")
        }
        try Task.checkCancellation()
        let generation = authenticationGeneration
        var request = URLRequest(url: URL(string: "https://" + host + path)!)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(WBISigner.query(ClientProtocol.signed(form)).utf8)
        let data: Data
        let response: URLResponse
        do {
            if writing {
                let session = session
                (data, response) = try await Task { try await session.data(for: request) }.value
            } else {
                (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
            }
        } catch {
            if writing { throw APIError(code: -90001, message: "请求结果未确认，请刷新互动状态后再操作") }
            throw error
        }
        guard generation == authenticationGeneration else { throw CancellationError() }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["code"] is NSNumber
        else { throw APIError(code: writing ? -90001 : -1, message: "请求结果无法确认，请刷新状态") }
        return root
    }

    public func clientLoginCode() async throws -> LoginCode {
        let root = try await clientRequest(
            "/x/passport-tv-login/qrcode/auth_code",
            form: ["local_id": "0", "platform": "android", "mobi_app": "android_hd"])
        guard root["code"] as? Int == 0, let data = root["data"] as? [String: Any],
            let key = data["auth_code"] as? String, !key.isEmpty,
            let raw = data["url"] as? String, let url = URL(string: raw),
            url.scheme == "https", url.host == "passport.bilibili.com"
        else { throw APIError(code: root["code"] as? Int ?? -1, message: "无法生成客户端登录二维码") }
        return LoginCode(url: raw, key: key)
    }

    public func pollClientLogin(_ key: String) async throws -> LoginStatus {
        let root = try await clientRequest(
            "/x/passport-tv-login/qrcode/poll", form: ["auth_code": key, "local_id": "0"])
        switch root["code"] as? Int {
        case 86039, 86101: return .waiting
        case 86090: return .scanned
        case 86038: return .expired
        case 0:
            guard let data = root["data"] as? [String: Any] else {
                throw APIError(code: -1, message: "登录信息不完整")
            }
            try installClientLogin(data)
            return .success
        default:
            throw APIError(
                code: root["code"] as? Int ?? -1,
                message: root["message"] as? String ?? "二维码已失效，请刷新")
        }
    }

    func authorizedClient(expectedUserID: Int64? = nil) throws -> ClientAuthorization? {
        guard let credential = clientAuthorization else { return nil }
        let id = Int64(officialPlayerCookies().first { $0.name == "DedeUserID" }?.value ?? "") ?? 0
        guard credential.isValid(accountID: id), expectedUserID == nil || expectedUserID == id
        else {
            throw APIError(code: -101, message: "客户端授权已过期或账号已变化，请重新扫码登录")
        }
        return credential
    }

    func clientTriple(aid: Int64, credential: ClientAuthorization) async throws -> VideoRelation {
        let generation = authenticationGeneration
        let root = try await clientRequest(
            "/x/v2/view/like/triple",
            form: ["aid": String(aid), "access_key": credential.accessToken], writing: true)
        guard root["code"] as? Int == 0 else {
            throw APIError(
                code: root["code"] as? Int ?? -1, message: root["message"] as? String ?? "三连未成功")
        }
        for delay in [0, 250, 500, 1000, 2000] {
            do {
                try await Task.sleep(for: .milliseconds(delay))
                guard generation == authenticationGeneration else { throw CancellationError() }
                let data = try await request(
                    "/x/web-interface/archive/relation", params: ["aid": String(aid)],
                    expectedUserID: credential.accountID)
                guard generation == authenticationGeneration else { throw CancellationError() }
                if data["like"] is Bool, data["coin"] is NSNumber, data["favorite"] is Bool {
                    var result = VideoRelation(data)
                    if result.liked && result.coins > 0 && result.favorited {
                        result.coinsAreTotal = true
                        return result
                    }
                }
            } catch is CancellationError { throw CancellationError() } catch {}
        }
        throw APIError(code: -90001, message: "三连已提交，服务器状态尚未确认，请刷新互动状态")
    }
}
