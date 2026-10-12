import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Media playback

    func switchPlayer() {
        smartSubtitles.redetect()
        watchHistoryReporter.flush()
        saveSession()
        mpv?.pause()
        player.pause()
        playing = false
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            officialCore = false
            seek(time)
        } else {
            officialCore = true
        }
    }
    func activate(_ id: String, force: Bool = false, autoplay: Bool = false) {
        if managesPlaybackTabs {
            activatePlaybackTab(id, force: force, autoplay: autoplay)
            return
        }
        guard tabs.contains(where: { $0.id == id }) else { return }
        selected = id
        if mediaID == id && !force {
            if autoplay {
                if officialCore {
                    officialWebView?.evaluateJavaScript("window.biliPlayer?.play()")
                } else {
                    playbackIntent = true
                    startBufferedPlayback()
                }
            }
            return
        }
        saveSession()
        watchHistoryReporter.flush()
        officialCore = false
        mpv?.pause()
        player.pause()
        playing = false
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        let generation = UUID()
        videoGeneration = generation
        subtitleGeneration = UUID()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
        statusObserver = nil
        durationObserver = nil
        mediaID = id
        smartSubtitles.configure(video: id, cid: nil, owner: nil, track: "")
        detail = nil
        pageID = nil
        cues = []
        tracks = []
        trackID = ""
        time = 0
        playerError = nil
        subtitleError = nil
        videoLoading = true
        subtitleLoading = false
        videoTask = Task {
            do {
                let source = tabs.first(where: { $0.id == id })?.video
                let loaded: VideoDetail
                if let source, source.episodeID != nil, let cid = source.historyCID {
                    loaded = VideoDetail(
                        video: source, pages: [VideoPage(cid: cid, number: 1, title: source.title)],
                        description: "番剧内容的播放权限由 B 站账号及地区授权决定。")
                } else {
                    loaded = try await api.detail(id)
                }
                guard !Task.isCancelled, generation == videoGeneration else { return }
                detail = loaded
                if let index = tabs.firstIndex(where: { $0.id == id }) {
                    tabs[index].video = loaded.video
                }
                let saved = tabs.first(where: { $0.id == id })
                guard
                    let page = loaded.pages.first(where: { $0.cid == saved?.cid })
                        ?? loaded.pages.first
                else { throw APIError(code: -1, message: "视频没有可播放的分 P") }
                pageID = page.cid
                await loadMedia(
                    id: id, cid: page.cid, position: saved?.position ?? 0, generation: generation,
                    autoplay: autoplay)
            } catch {
                guard !Task.isCancelled, generation == videoGeneration else { return }
                playerError = error.localizedDescription
                videoLoading = false
            }
        }
    }
    func selectPage(_ cid: Int64) {
        guard let id = selected, cid != pageID else { return }
        watchHistoryReporter.flush()
        saveSession()
        mpv?.pause()
        player.pause()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        subtitleGeneration = UUID()
        let generation = UUID()
        videoGeneration = generation
        smartSubtitles.configure(video: id, cid: cid, owner: detail?.video.ownerID, track: "")
        pageID = cid
        time = 0
        playing = false
        cues = []
        tracks = []
        trackID = ""
        subtitleError = nil
        if let i = tabs.firstIndex(where: { $0.id == id }) {
            tabs[i].cid = cid
            tabs[i].position = 0
        }
        videoTask = Task { await loadMedia(id: id, cid: cid, position: 0, generation: generation) }
    }
    private func loadMedia(
        id: String, cid: Int64, position: Double, generation: UUID, autoplay: Bool = false
    ) async {
        smartSubtitles.configure(video: id, cid: cid, owner: detail?.video.ownerID, track: "")
        videoLoading = true
        playerError = nil
        subtitleLoading = true
        duration = 0
        danmaku.configure(cid: cid)
        danmaku.update(time: position, duration: 0, api: api)
        // Subtitles are independent: media failure must not discard a readable transcript.
        subtitleTask = Task {
            do {
                let result = try await api.subtitleTracks(bvid: id, cid: cid)
                guard !Task.isCancelled, generation == videoGeneration else { return }
                tracks = result
                if let first = result.first {
                    selectTrack(first.id)
                } else {
                    subtitleLoading = false
                }
            } catch {
                guard !Task.isCancelled, generation == videoGeneration else { return }
                subtitleError = error.localizedDescription
                subtitleLoading = false
            }
        }
        do {
            let source = try await api.playback(
                bvid: id, cid: cid, quality: 80, episodeID: detail?.video.episodeID)
            guard !Task.isCancelled, generation == videoGeneration else { return }
            let core = try ensureMPV()
            quality = source.quality
            qualityID = source.qualityID
            playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
            qualities = source.qualities
            playbackIntent = autoplay && playbackTabActive
            core.speed = playbackRate
            awaitingMPVLoad = true
            try core.load(source, position: position, autoplay: playbackIntent)
        } catch {
            guard !Task.isCancelled, generation == videoGeneration else { return }
            playerError = error.localizedDescription
            videoLoading = false
        }
    }

    private func ensureMPV() throws -> MPVPlayer {
        if let mpv { return mpv }
        let core = try MPVPlayer()
        core.muted = player.isMuted || CommandLine.arguments.contains("--mute")
        core.volume = Double(player.volume)
        core.onUpdate = { [weak self, weak core] time, duration, playing, buffering in
            guard let self, let core, !self.officialCore else { return }
            self.updatePlayback(
                time: time, duration: duration, playing: playing, buffering: buffering)
            if self.awaitingMPVLoad && core.loaded {
                self.awaitingMPVLoad = false
                self.videoLoading = false
            }
            if let failure = core.failure {
                self.playerError = failure
                self.videoLoading = false
            }
            if self.playbackTabActive { self.updateDanmaku() }
            if core.loaded && self.playbackTabActive && Date().timeIntervalSince(self.lastSaved) > 5
            {
                self.saveSession(updateTabs: false)
            }
        }
        mpv = core
        return core
    }

    private func loadAVMedia(
        id: String, cid: Int64, position: Double, generation: UUID, autoplay: Bool
    ) async {
        do {
            let (playback, item) = try await playableMedia(id: id, cid: cid, quality: 80)
            guard !Task.isCancelled, generation == videoGeneration else { return }
            quality = playback.quality
            qualityID = playback.qualityID
            playbackCodec = playback.videoStream?.codec ?? "MP4"
            qualities = playback.qualities
            playbackIntent = autoplay && playbackTabActive
            observeMediaStatus(item, playback: playback, generation: generation)
            observeDuration(item, generation: generation)
            player.replaceCurrentItem(with: item)
            if position > 0 {
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
            }
            guard !Task.isCancelled, generation == videoGeneration, selected == id,
                player.currentItem === item
            else { return }
            if autoplay && playbackTabActive { startBufferedPlayback() }
        } catch {
            guard !Task.isCancelled, generation == videoGeneration else { return }
            playerError = error.localizedDescription
        }
        if generation == videoGeneration { videoLoading = false }
    }
    private func playableMedia(
        id: String, cid: Int64, quality: Int,
        allowAV1: Bool = true, allowHEVC: Bool = true
    ) async throws -> (Playback, AVPlayerItem) {
        var result = try await api.playback(
            bvid: id, cid: cid, quality: quality,
            episodeID: detail?.video.episodeID, allowAV1: allowAV1, allowHEVC: allowHEVC)
        while true {
            try Task.checkCancellation()
            do { return (result, try await prepareMedia(result)) } catch {
                try Task.checkCancellation()
                guard let stream = result.videoStream else { throw error }
                let isAV1 = stream.codec.hasPrefix("av01.")
                let isHEVC = stream.codec.hasPrefix("hev1") || stream.codec.hasPrefix("hvc1")
                if isAV1 || isHEVC {
                    result = try await api.playback(
                        bvid: id, cid: cid, quality: quality,
                        episodeID: detail?.video.episodeID, allowAV1: false, allowHEVC: isAV1)
                    continue
                }
                let fallback = try await api.playback(
                    bvid: id, cid: cid, quality: quality,
                    episodeID: detail?.video.episodeID, preferDASH: false)
                let item = try await prepareMedia(fallback)
                try Task.checkCancellation()
                toast = "分离流暂时无法加载，已回退到 " + fallback.quality
                return (fallback, item)
            }
        }
    }

    func observeMediaStatus(_ item: AVPlayerItem, playback: Playback, generation: UUID? = nil) {
        let generation = generation ?? videoGeneration
        failedCodecItem = nil
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, !self.officialCore, generation == self.videoGeneration,
                    self.player.currentItem === item, item.status == .failed,
                    self.failedCodecItem != ObjectIdentifier(item)
                else { return }
                self.failedCodecItem = ObjectIdentifier(item)
                let codec = playback.videoStream?.codec ?? ""
                let isAV1 = codec.hasPrefix("av01.")
                let isHEVC = codec.hasPrefix("hev1") || codec.hasPrefix("hvc1")
                if isAV1 || isHEVC {
                    let current = self.player.currentTime().seconds
                    self.qualitySwitchState =
                        self.qualitySwitchState
                        ?? (current.isFinite ? current : self.time, self.playbackIntent)
                    self.toast = isAV1 ? "AV1 加载失败，正在尝试 HEVC／H.264" : "HEVC 加载失败，正在尝试 H.264"
                    self.changeQuality(
                        self.qualityID, allowAV1: false, allowHEVC: isAV1, force: true)
                } else {
                    self.playerError = item.error?.localizedDescription ?? "媒体加载失败"
                }
            }
        }
    }

    private func prepareMedia(_ playback: Playback) async throws -> AVPlayerItem {
        if playback.videoStream != nil {
            let (loader, item) = try await DASHResourceLoader.prepare(playback)
            if Task.isCancelled {
                loader.invalidate()
                throw CancellationError()
            }
            mediaLoader?.invalidate()
            mediaLoader = nil
            dashLoader?.invalidate()
            dashLoader = loader
            item.preferredForwardBufferDuration = 15
            return item
        }
        dashLoader?.invalidate()
        dashLoader = nil
        mediaLoader?.invalidate()
        let loader = MediaResourceLoader(url: playback.url)
        mediaLoader = loader
        let item = AVPlayerItem(asset: loader.asset)
        item.preferredForwardBufferDuration = 15
        return item
    }

    private func observeDuration(_ item: AVPlayerItem, generation: UUID) {
        durationObserver = item.observe(\.duration, options: [.initial, .new]) {
            [weak self] item, _ in
            let seconds = item.duration.seconds
            Task { @MainActor in
                guard let self, generation == self.videoGeneration else { return }
                if seconds.isFinite && seconds > 0 { self.duration = seconds }
            }
        }
    }
    func selectQuality(_ value: Int) { changeQuality(value) }

    private func changeQuality(
        _ value: Int, allowAV1: Bool = true, allowHEVC: Bool = true,
        force: Bool = false
    ) {
        guard let id = mediaID, let cid = pageID, force || value != qualityID || videoLoading else {
            return
        }
        qualityTask?.cancel()
        let generation = videoGeneration
        let request = UUID()
        qualityGeneration = request
        let current = mpv?.time ?? player.currentTime().seconds
        let position = qualitySwitchState?.position ?? (current.isFinite ? current : time)
        let resume = qualitySwitchState?.resume ?? (mpv?.playing ?? (player.rate != 0))
        qualitySwitchState = (position, resume)
        playbackIntent = resume
        mpv?.pause()
        player.pause()
        videoLoading = true
        playerError = nil
        qualityTask = Task { [self] in
            do {
                if let mpv {
                    let source = try await api.playback(
                        bvid: id, cid: cid, quality: value, episodeID: detail?.video.episodeID)
                    guard !Task.isCancelled, generation == videoGeneration,
                        request == qualityGeneration
                    else { return }
                    quality = source.quality
                    qualityID = source.qualityID
                    qualities = source.qualities
                    playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
                    awaitingMPVLoad = true
                    try mpv.load(source, position: position, autoplay: resume && playbackTabActive)
                    qualitySwitchState = nil
                    return
                }
                let (result, item) = try await playableMedia(
                    id: id, cid: cid, quality: value,
                    allowAV1: allowAV1, allowHEVC: allowHEVC)
                guard !Task.isCancelled, generation == videoGeneration, request == qualityGeneration
                else { return }
                quality = result.quality
                qualityID = result.qualityID
                playbackCodec = result.videoStream?.codec ?? "MP4"
                qualities = result.qualities
                observeMediaStatus(item, playback: result, generation: generation)
                observeDuration(item, generation: generation)
                player.replaceCurrentItem(with: item)
                await player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
                guard !Task.isCancelled, generation == videoGeneration, request == qualityGeneration
                else { return }
                if resume && playbackTabActive {
                    startBufferedPlayback()
                }
                if result.qualityID != value {
                    toast = "请求的清晰度未返回，当前使用" + result.quality + "。当前取流格式或账号权限可能受限。"
                }
            } catch {
                if !Task.isCancelled, generation == videoGeneration, request == qualityGeneration {
                    playerError = error.localizedDescription
                }
            }
            if !Task.isCancelled, generation == videoGeneration, request == qualityGeneration {
                videoLoading = false
                qualitySwitchState = nil
            }
        }
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite else { return }
        smartSubtitles.resetAfterSeek()
        if officialCore {
            if seconds.isFinite {
                officialWebView?.evaluateJavaScript("window.biliPlayer?.seek( \(max(0, seconds)));")
            }
            return
        }
        if let mpv {
            mpv.seek(seconds)
            return
        }
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
            toleranceAfter: .zero)
    }
    /// Let AVPlayer build a safety buffer and resume automatically after network stalls.
    func startBufferedPlayback() {
        if let mpv {
            mpv.speed = playbackRate
            mpv.play()
            return
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = Float(playbackRate)
        player.play()
    }

    func togglePlayback() {
        if managesPlaybackTabs {
            if let selected { playbackInstances[selected]?.togglePlayback() }
            return
        }
        if officialCore {
            officialWebView?.evaluateJavaScript(
                "{ const p=window.biliPlayer; if(p) { if(p.isPaused()) p.play(); else p.pause(); } }"
            )
            return
        }
        if let mpv {
            playbackIntent = !playbackIntent
            if playbackIntent { mpv.play() } else { mpv.pause() }
            playing = playbackIntent
            return
        }
        if playbackIntent || player.timeControlStatus != .paused {
            mpv?.pause()
            player.pause()
            playbackIntent = false
        } else {
            playbackIntent = true
            startBufferedPlayback()
        }
        playing = playbackIntent
    }
    func setRate(_ value: Double) {
        playbackRate = value
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.setPlaybackRate(\(value));")
            return
        }
        mpv?.speed = value
        if mpv == nil && playing { player.rate = Float(value) }
    }
    func updateDanmaku() {
        guard !officialCore else { return }
        danmaku.update(time: time, duration: duration, api: api)
    }
    func isPlaying(_ id: String) -> Bool {
        if managesPlaybackTabs { return playbackInstances[id]?.playing ?? false }
        return id == mediaID && playing
    }
    func stopMedia() {
        smartSubtitles.configure(video: nil, cid: nil, owner: nil, track: "")
        watchHistoryReporter.flush()
        videoTask?.cancel()
        subtitleTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        videoGeneration = UUID()
        subtitleGeneration = UUID()
        mpv?.pause()
        player.pause()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
        mediaLoader?.invalidate()
        mediaLoader = nil
        dashLoader?.invalidate()
        dashLoader = nil
        statusObserver = nil
        durationObserver = nil
        mediaID = nil
        playing = false
        danmaku.configure(cid: nil)
        duration = 0
        buffering = false
    }

}
