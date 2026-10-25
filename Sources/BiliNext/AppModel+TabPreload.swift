import Foundation

extension AppModel {
    struct TabPreloadJob {
        let id: UUID
        let task: Task<Void, Never>
    }

    /// Limit startup bursts, while eventually loading every restored/background tab.
    static let tabPreloadConcurrency = 2

    func startTabPreloads() {
        guard managesPlaybackTabs else { return }
        tabPreloadsEnabled = true
        preloadBackgroundTabs()
    }

    func preloadBackgroundTabs() {
        guard managesPlaybackTabs, tabPreloadsEnabled else { return }
        for tab in tabs where tab.id != selected {
            guard playbackInstances[tab.id]?.tabLoadStarted != true,
                tabPreloadJobs[tab.id] == nil, !tabPreloadQueue.contains(tab.id)
            else { continue }
            tabPreloadQueue.append(tab.id)
        }
        startNextTabPreload()
    }

    func cancelTabPreload(_ id: String) {
        tabPreloadQueue.removeAll { $0 == id }
        tabPreloadJobs.removeValue(forKey: id)?.task.cancel()
        startNextTabPreload()
    }

    func cancelAllTabPreloads() {
        tabPreloadsEnabled = false
        tabPreloadQueue = []
        let jobs = tabPreloadJobs.values
        tabPreloadJobs = [:]
        for job in jobs { job.task.cancel() }
    }

    private func startNextTabPreload() {
        guard tabPreloadsEnabled else { return }
        while tabPreloadJobs.count < Self.tabPreloadConcurrency, !tabPreloadQueue.isEmpty {
            let id = tabPreloadQueue.removeFirst()
            guard id != selected, let tab = tabs.first(where: { $0.id == id }),
                playbackInstances[id]?.tabLoadStarted != true
            else { continue }
            let instance = playbackInstance(for: tab)
            instance.playbackTabActive = false
            instance.activate(id, autoplay: false)
            let request = UUID()
            let account = accountGeneration
            let task = Task { [weak self, weak instance] in
                defer {
                    if self?.tabPreloadJobs[id]?.id == request {
                        self?.tabPreloadJobs[id] = nil
                        self?.startNextTabPreload()
                    }
                }
                guard let instance else { return }
                await instance.videoTask?.value
                await instance.browseTask?.value
                // FILE_LOADED arrives after loadMedia returns. Keep the slot until the
                // paused player has actually opened its source, or reported an error.
                while !Task.isCancelled, self?.accountGeneration == account,
                    instance.videoLoading || instance.liveSession?.loading == true
                        || instance.memberSpace?.uploadsLoading == true
                {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard !Task.isCancelled, self?.accountGeneration == account else { return }
                await instance.commentListState?.loader.task?.value
                guard !Task.isCancelled, self?.accountGeneration == account else { return }
                NSLog(
                    "Background tab ready: %@ player=%@ comments=%ld", id,
                    instance.mpv?.loaded == true ? "loaded" : "none",
                    instance.commentListState?.loader.comments.count ?? 0)
            }
            tabPreloadJobs[id] = TabPreloadJob(id: request, task: task)
        }
    }
}
