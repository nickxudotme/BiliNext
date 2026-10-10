import Foundation

/// Validates Range before accepting data and caps accumulation, including dishonest CDN replies.
final class DASHHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Pending {
        let key: UUID
        let range: ClosedRange<Int64>
        let continuation: CheckedContinuation<Data, Error>
        let task: URLSessionDataTask
        var data = Data()
        init(
            key: UUID, range: ClosedRange<Int64>, continuation: CheckedContinuation<Data, Error>,
            task: URLSessionDataTask
        ) {
            self.key = key
            self.range = range
            self.continuation = continuation
            self.task = task
        }
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var cancelled: Set<UUID> = []
    private var stopped = false
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        session = URLSession(
            configuration: configuration, delegate: self, delegateQueue: operations)
    }

    func data(for request: URLRequest, range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound - range.lowerBound < 32 * 1024 * 1024 else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        let key = UUID()
        defer { _ = lock.withLock { cancelled.remove(key) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if stopped || cancelled.remove(key) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let task = session.dataTask(with: request)
                pending[task.taskIdentifier] = Pending(
                    key: key, range: range, continuation: continuation, task: task)
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            if let entry = self.pending.values.first(where: { $0.key == key }) {
                self.lock.unlock()
                entry.task.cancel()
            } else {
                self.cancelled.insert(key)
                self.lock.unlock()
            }
        }
    }

    func invalidateAndCancel() {
        lock.lock()
        stopped = true
        cancelled.removeAll()
        lock.unlock()
        session.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let entry = pending[dataTask.taskIdentifier]
        lock.unlock()
        guard let entry, let http = response as? HTTPURLResponse,
            http.statusCode == 206,
            (http.value(forHTTPHeaderField: "Content-Range") ?? "").hasPrefix(
                "bytes \(entry.range.lowerBound)-\(entry.range.upperBound)/"),
            response.expectedContentLength == entry.range.upperBound - entry.range.lowerBound + 1
        else {
            complete(dataTask.taskIdentifier, error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let entry = pending[dataTask.taskIdentifier] else {
            lock.unlock()
            return
        }
        let limit = entry.range.upperBound - entry.range.lowerBound + 1
        guard entry.data.count <= limit - Int64(data.count) else {
            lock.unlock()
            complete(dataTask.taskIdentifier, error: URLError(.dataLengthExceedsMaximum))
            dataTask.cancel()
            return
        }
        entry.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        complete(task.taskIdentifier, error: error)
    }

    private func complete(_ id: Int, error: Error?) {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return }
        if let error {
            entry.continuation.resume(throwing: error)
        } else if entry.data.count != entry.range.upperBound - entry.range.lowerBound + 1 {
            entry.continuation.resume(throwing: URLError(.badServerResponse))
        } else {
            entry.continuation.resume(returning: entry.data)
        }
    }
}
