import Foundation

public struct MediaRangeResponse: Sendable {
    public let data: Data
    public let total: Int64
}

public struct PartialMediaRead: Error, Sendable {
    public let response: MediaRangeResponse
}

public enum MediaURLPolicy {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
            url.port == nil || url.port == 443, let host = url.host?.lowercased()
        else { return false }
        return ["bilivideo.com", "bilivideo.cn", "akamaized.net", "szbdyd.com", "mountaintoys.cn"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

private final class MediaRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let cancel = cancelled
        lock.unlock()
        if cancel { task.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// A shared connection pool with strict Range validation and bounded response memory.
public final class MediaRangeTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let start: Int64
        let length: Int
        let continuation: CheckedContinuation<MediaRangeResponse, Error>
        var data = Data()
        var total: Int64?
        var expected = 0
        var error: Error?
        init(
            start: Int64, length: Int, continuation: CheckedContinuation<MediaRangeResponse, Error>
        ) {
            self.start = start
            self.length = length
            self.continuation = continuation
        }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var session: URLSession!
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    public func close() { session.invalidateAndCancel() }
    public func read(_ url: URL, start: Int64, length: Int, timeout: TimeInterval = 8) async throws
        -> MediaRangeResponse
    {
        guard MediaURLPolicy.allows(url), start >= 0, (1...1_048_576).contains(length),
            start <= Int64.max - Int64(length)
        else {
            throw APIError(code: -1, message: "媒体范围或地址无效")
        }
        try Task.checkCancellation()
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpShouldHandleCookies = false
        request.setValue("bytes=\(start)-\(start + Int64(length) - 1)", forHTTPHeaderField: "Range")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let cancellation = MediaRequestCancellation()
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                cancellation.cancel()
            } catch {}
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[task.taskIdentifier] = Pending(
                    start: start, length: length, continuation: continuation)
                lock.unlock()
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let values =
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?
            .replacingOccurrences(of: "bytes ", with: "").split(whereSeparator: {
                $0 == "-" || $0 == "/"
            }).compactMap { Int64($0) } ?? []
        let type = response.mimeType?.lowercased()
        if let http = response as? HTTPURLResponse, http.statusCode == 206,
            http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes ") == true,
            values.count == 3,
            values[0] == item.start, values[2] > item.start,
            values[1] == min(values[2] - 1, item.start + Int64(item.length) - 1),
            values[1] >= values[0],
            type == nil || ["video/mp4", "audio/mp4", "application/octet-stream"].contains(type!)
        {
            item.total = values[2]
            item.expected = Int(values[1] - values[0] + 1)
            if response.expectedContentLength >= 0
                && response.expectedContentLength != Int64(item.expected)
            {
                item.error = APIError(code: -1, message: "媒体响应长度不一致")
            }
        } else {
            item.error = APIError(code: -1, message: "服务器没有返回有效的媒体分块")
        }
        let valid = item.error == nil
        lock.unlock()
        completionHandler(valid ? .allow : .cancel)
    }
    public func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data
    ) {
        lock.lock()
        guard let item = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let valid = item.error == nil && item.data.count + data.count <= item.expected
        if valid {
            item.data.append(data)
        } else {
            item.error = APIError(code: -1, message: "媒体分块超出请求范围")
        }
        lock.unlock()
        if !valid { dataTask.cancel() }
    }
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        lock.lock()
        let item = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let item else { return }
        if let failure = item.error {
            item.continuation.resume(throwing: failure)
        } else if let total = item.total, item.data.count == item.expected {
            item.continuation.resume(returning: MediaRangeResponse(data: item.data, total: total))
        } else if let total = item.total, !item.data.isEmpty {
            item.continuation.resume(
                throwing: PartialMediaRead(
                    response: MediaRangeResponse(data: item.data, total: total)))
        } else {
            item.continuation.resume(throwing: error ?? APIError(code: -1, message: "媒体分块不完整"))
        }
    }
    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MediaURLPolicy.allows(url) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.httpShouldHandleCookies = false
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(redirected)
    }
}
