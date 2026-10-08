import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Supplies HTTP byte ranges through AVFoundation's public resource-loader API.
/// Bilibili's CDN requires the same Referer/User-Agent as its media requests.
final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate,
    @unchecked Sendable
{
    let asset: AVURLAsset
    private let source: URL
    private let queue = DispatchQueue(label: "me.nickxu.BiliNext.media")
    private var requests: [Int: Pending] = [:]
    private var invalidated = false
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return URLSession(configuration: config, delegate: self, delegateQueue: operations)
    }()
    private final class Pending {
        let loading: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        let start: Int64
        let end: Int64?
        var offset: Int64 = 0
        init(
            loading: AVAssetResourceLoadingRequest, task: URLSessionDataTask, start: Int64,
            end: Int64?
        ) {
            self.loading = loading
            self.task = task
            self.start = start
            self.end = end
        }
    }
    init(url: URL) {
        source = url
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "bilinext-media"
        asset = AVURLAsset(url: components.url!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }
    func invalidate() {
        queue.async { [self] in
            guard !invalidated else { return }
            invalidated = true
            for item in requests.values {
                item.task.cancel()
                item.loading.finishLoading(with: URLError(.cancelled))
            }
            requests.removeAll()
            session.invalidateAndCancel()
        }
    }
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loading: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !invalidated else {
            loading.finishLoading(with: URLError(.cancelled))
            return true
        }
        let data = loading.dataRequest
        let start = max(0, max(data?.requestedOffset ?? 0, data?.currentOffset ?? 0))
        let end: Int64? =
            data == nil
            ? 1
            : data!.requestsAllDataToEndOfResource
                ? nil : max(start, data!.requestedOffset + Int64(data!.requestedLength) - 1)
        var request = URLRequest(url: source)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(
            "bytes=\(start)-\(end.map(String.init) ?? "")", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        requests[task.taskIdentifier] = Pending(
            loading: loading, task: task, start: start, end: end)
        task.resume()
        return true
    }
    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader, didCancel loading: AVAssetResourceLoadingRequest
    ) {
        guard let item = requests.values.first(where: { $0.loading === loading }) else { return }
        requests[item.task.taskIdentifier] = nil
        item.task.cancel()
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let item = requests[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode) else {
            item.loading.finishLoading(
                with: NSError(
                    domain: "BiliNext.Media",
                    code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                    userInfo: [NSLocalizedDescriptionKey: "媒体服务器拒绝了请求，请刷新视频后重试。"]))
            requests[dataTask.taskIdentifier] = nil
            completionHandler(.cancel)
            return
        }
        let range = http.value(forHTTPHeaderField: "Content-Range")
        let total =
            range?.split(separator: "/").last.flatMap { Int64($0) }
            ?? response.expectedContentLength
        if http.statusCode == 206 {
            let interval = range?.split(separator: " ").last?.split(separator: "/").first
            item.offset = interval?.split(separator: "-").first.flatMap { Int64($0) } ?? item.start
        }
        if let info = item.loading.contentInformationRequest {
            info.contentType =
                UTType(mimeType: response.mimeType ?? "video/mp4")?.identifier
                ?? AVFileType.mp4.rawValue
            info.contentLength = max(0, total)
            info.isByteRangeAccessSupported =
                http.statusCode == 206
                || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() == "bytes"
        }
        if item.loading.dataRequest == nil {
            item.loading.finishLoading()
            requests[dataTask.taskIdentifier] = nil
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let item = requests[dataTask.taskIdentifier], let target = item.loading.dataRequest
        else { return }
        let dataEnd = item.offset + Int64(data.count)
        let wantedStart = max(item.start, target.currentOffset)
        let lower = min(Int64(data.count), max(0, wantedStart - item.offset))
        let upper = min(
            Int64(data.count), max(0, (item.end.map { $0 + 1 } ?? dataEnd) - item.offset))
        if upper > lower { target.respond(with: data.subdata(in: Int(lower)..<Int(upper))) }
        item.offset = dataEnd
        if let end = item.end, target.currentOffset > end {
            item.loading.finishLoading()
            requests[dataTask.taskIdentifier] = nil
            dataTask.cancel()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        guard let item = requests.removeValue(forKey: task.taskIdentifier) else { return }
        if let error {
            item.loading.finishLoading(with: error)
        } else {
            item.loading.finishLoading()
        }
    }
}
