import Foundation

public enum CommentVideoLinks {
    public static func allowed(_ raw: String) -> URL? {
        guard var url = URLComponents(string: raw),
            ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil, url.port == nil,
            let host = url.host?.lowercased(),
            host == "b23.tv"
                || ((host == "bilibili.com" || host.hasSuffix(".bilibili.com"))
                    && url.path.hasPrefix("/video/"))
        else { return nil }
        url.scheme = "https"
        url.query = nil
        url.fragment = nil
        return url.url
    }
    public static func parse(_ text: String) -> [URL] {
        guard text.utf16.count <= 64_000,
            let expression = try? NSRegularExpression(
                pattern: #"https?://[^\s<>]+|BV[0-9A-Za-z]{10}"#)
        else { return [] }
        var seen = Set<URL>()
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap
        { match -> URL? in
            guard let range = Range(match.range, in: text) else { return nil }
            let raw = String(text[range]).trimmingCharacters(
                in: CharacterSet(charactersIn: "。，、；;！!？?）)]】>"))
            return allowed(raw.hasPrefix("BV") ? "https://www.bilibili.com/video/" + raw : raw)
        }.filter { seen.insert($0).inserted }.prefix(2).map { $0 }
    }
}

private final class CommentLinkRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

public actor CommentVideoResolver {
    private let api: BilibiliAPI
    private let session: URLSession
    private var cached: [URL: Video] = [:]
    private var failures: [URL: Date] = [:]
    private var pending: [URL: Task<Video?, Never>] = [:]
    private var active = 0
    public init(api: BilibiliAPI) {
        self.api = api
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        session = URLSession(
            configuration: config, delegate: CommentLinkRedirectPolicy(), delegateQueue: nil)
    }
    public func resolve(_ url: URL) async -> Video? {
        guard CommentVideoLinks.allowed(url.absoluteString) != nil else { return nil }
        if let video = cached[url] { return video }
        if let failed = failures[url], Date().timeIntervalSince(failed) < 60 { return nil }
        if let task = pending[url] { return await task.value }
        guard pending.count < 48 else { return nil }
        let task = Task { await self.fetch(url) }
        pending[url] = task
        let video = await task.value
        pending[url] = nil
        if let video {
            if cached.count >= 128 { cached.removeAll(keepingCapacity: true) }
            cached[url] = video
        } else {
            if failures.count >= 128 { failures.removeAll(keepingCapacity: true) }
            failures[url] = Date()
        }
        return video
    }
    private func fetch(_ original: URL) async -> Video? {
        do {
            while active >= 3 { try await Task.sleep(for: .milliseconds(100)) }
            active += 1
            defer { active -= 1 }
            var url = original
            for _ in 0..<5 where url.host?.lowercased() == "b23.tv" {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                request.httpShouldHandleCookies = false
                request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                    (300..<400).contains(http.statusCode),
                    let location = http.value(forHTTPHeaderField: "Location"),
                    let destination = URL(string: location, relativeTo: url)?.absoluteURL,
                    let next = CommentVideoLinks.allowed(destination.absoluteString)
                else { return nil }
                url = next
            }
            return try await api.videoLinkMetadata(url)
        } catch { return nil }
    }
}

extension BilibiliAPI {
    func videoLinkMetadata(_ url: URL) async throws -> Video? {
        guard url.host != "b23.tv" else { return nil }
        let identity = url.lastPathComponent
        let params: [String: String]
        if let bvid = Video.extractBVID(identity) {
            params = ["bvid": bvid]
        } else if identity.hasPrefix("av"), let aid = Int64(identity.dropFirst(2)), aid > 0 {
            params = ["aid": String(aid)]
        } else {
            return nil
        }
        return video(try await request("/x/web-interface/view", params: params))
    }
}
