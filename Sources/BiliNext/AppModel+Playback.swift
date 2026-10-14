import AVKit
import BiliNextCore
import Combine
import SwiftUI
import WebKit

extension AppModel {
    // MARK: - Media playback

    func switchPlayer() {
        let reloadNative = mpv?.failure != nil || mpv?.loaded != true
        cancelPlaybackRecovery()
        videoTask?.cancel()
        qualityTask?.cancel()
        qualitySwitchState = nil
        smartSubtitles.redetect()
        watchHistoryReporter.flush()
        saveSession()
        mpv?.pause()
        player.pause()
        playing = false
        if officialCore {
            officialWebView?.evaluateJavaScript("window.biliPlayer?.pause()")
            officialCore = false
            if reloadNative, let id = mediaID, let cid = pageID {
                let position = time
                let generation = videoGeneration
                playbackIntent = false
                videoTask = Task {
                    await loadMedia(id: id, cid: cid, position: position, generation: generation)
                }
            } else {
                seek(time)
            }
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
        if let roomID = LiveSession.roomID(id) {
            activateLive(roomID, force: force, autoplay: autoplay)
            return
        }
        if let mid = MemberSpace.mid(id) {
            activateSpace(mid, force: force)
            return
        }
        if liveSession != nil { stopMedia() }
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
        cancelPlaybackRecovery()
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
        mediaID = id
        smartSubtitles.configure(video: id, cid: nil, owner: nil, track: "")
        detail = nil
        pageID = nil
        resetSecondarySubtitles()
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
                    // The page endpoint adds the UP card, tags, 合集 and related videos; the
                    // plain one remains the fallback.
                    if let page = try? await api.videoPage(id) {
                        loaded = page
                    } else {
                        loaded = try await api.detail(id)
                    }
                }
                guard !Task.isCancelled, generation == videoGeneration else { return }
                detail = loaded
                loadRelation(for: loaded.video.bvid)
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
        cancelPlaybackRecovery()
        saveSession()
        mpv?.pause()
        player.pause()
        mpv?.stop()
        player.replaceCurrentItem(with: nil)
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
        resetSecondarySubtitles()
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
        let qualityRequest = qualityGeneration
        smartSubtitles.configure(video: id, cid: cid, owner: detail?.video.ownerID, track: "")
        videoLoading = true
        playerError = nil
        subtitleLoading = true
        duration = 0
        danmaku.configure(cid: cid)
        danmaku.update(time: position, duration: 0, api: api)
        highEnergy = nil
        let aid = detail?.video.aid
        Task {
            // Optional decoration: a missing or failed curve leaves the plain progress bar.
            let curve = try? await api.highEnergy(aid: aid, bvid: id, cid: cid)
            guard generation == videoGeneration else { return }
            highEnergy = curve
        }
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
            guard !Task.isCancelled, generation == videoGeneration,
                qualityRequest == qualityGeneration, !officialCore
            else { return }
            let core = try ensureMPV()
            quality = source.quality
            qualityID = source.qualityID
            playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
            qualities = source.qualities
            playbackIntent = autoplay && playbackTabActive
            core.speed = playbackRate
            try beginPlaybackRecovery(source, requestedQuality: 80, position: position, core: core)
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
            if let failure = core.failure {
                self.playbackRecovery?.failed(code: core.failureCode, message: failure)
                let recovering = self.playbackRecovery?.recovering == true
                self.updatePlayback(
                    time: self.recoveryPosition, duration: self.duration,
                    playing: recovering && self.playbackIntent && self.playbackTabActive,
                    buffering: recovering)
                if !recovering { self.videoLoading = false }
                return
            }
            if core.loaded { self.recoveryPosition = time }
            self.updatePlayback(
                time: time, duration: duration, playing: playing, buffering: buffering)
            if self.awaitingMPVLoad && core.loaded {
                self.awaitingMPVLoad = false
                self.videoLoading = false
                self.playbackRecovery?.loaded()
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

    func cancelPlaybackRecovery() {
        awaitingMPVLoad = false
        playbackRecovery?.cancel()
        playbackRecovery = nil
        recoveryGeneration = UUID()
    }

    private func beginPlaybackRecovery(
        _ source: Playback, requestedQuality: Int, position: Double, core: MPVPlayer
    ) throws {
        cancelPlaybackRecovery()
        recoveryPosition = max(0, position.isFinite ? position : 0)
        let request = recoveryGeneration
        let video = videoGeneration
        let id = mediaID
        let cid = pageID
        let episodeID = detail?.video.episodeID
        let session = UUID()
        let recovery = PlaybackRecovery(
            playback: source,
            fetch: { [weak self] options in
                guard let self, self.recoveryGeneration == request, self.videoGeneration == video,
                    self.mediaID == id, self.pageID == cid, let id, let cid, !self.officialCore
                else { throw CancellationError() }
                return try await self.api.playback(
                    bvid: id, cid: cid, quality: requestedQuality,
                    episodeID: episodeID, preferDASH: options.preferDASH,
                    allowAV1: options.allowAV1, allowHEVC: options.allowHEVC)
            },
            load: { [weak self, weak core] candidate, attempt, phase in
                guard let self, let core, self.recoveryGeneration == request,
                    self.videoGeneration == video, self.mediaID == id, self.pageID == cid,
                    !self.officialCore
                else { throw CancellationError() }
                self.quality = candidate.playback.quality
                self.qualityID = candidate.playback.qualityID
                self.qualities = candidate.playback.qualities
                self.playbackCodec = "mpv · " + (candidate.playback.videoStream?.codec ?? "MP4")
                self.awaitingMPVLoad = true
                core.speed = self.playbackRate
                try core.load(
                    candidate.playback, position: self.recoveryPosition,
                    autoplay: self.playbackIntent && self.playbackTabActive,
                    videoURL: candidate.video, audioURL: candidate.audio,
                    diagnostics: PlaybackDiagnosticContext(
                        session: session, requestedQuality: requestedQuality,
                        source: candidate, attempt: attempt, phase: phase))
            },
            onState: { [weak self] recovering, error in
                guard let self, self.recoveryGeneration == request, self.videoGeneration == video
                else { return }
                self.videoLoading = recovering
                self.buffering = recovering
                self.playerError = error
            })
        playbackRecovery = recovery
        do { try recovery.start() } catch {
            recovery.failed(code: (error as? MPVError)?.code, message: error.localizedDescription)
        }
    }

    func selectQuality(_ value: Int) { changeQuality(value) }

    private func changeQuality(_ value: Int) {
        guard let id = mediaID, let cid = pageID, value != qualityID || videoLoading else {
            return
        }
        let recovering = playbackRecovery?.recovering == true
        qualityTask?.cancel()
        cancelPlaybackRecovery()
        let generation = videoGeneration
        let request = UUID()
        qualityGeneration = request
        let current = recovering ? recoveryPosition : mpv?.time ?? player.currentTime().seconds
        let position = qualitySwitchState?.position ?? (current.isFinite ? current : time)
        let resume =
            qualitySwitchState?.resume
            ?? (recovering ? playbackIntent : mpv?.playing ?? (player.rate != 0))
        qualitySwitchState = (position, resume)
        playbackIntent = resume
        mpv?.pause()
        player.pause()
        videoLoading = true
        playerError = nil
        qualityTask = Task { [self] in
            do {
                let source = try await api.playback(
                    bvid: id, cid: cid, quality: value, episodeID: detail?.video.episodeID)
                guard !Task.isCancelled, generation == videoGeneration,
                    request == qualityGeneration
                else { return }
                let core = try ensureMPV()
                quality = source.quality
                qualityID = source.qualityID
                qualities = source.qualities
                playbackCodec = "mpv · " + (source.videoStream?.codec ?? "MP4")
                try beginPlaybackRecovery(
                    source, requestedQuality: value, position: position, core: core)
                qualitySwitchState = nil
                return
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
            recoveryPosition = max(0, seconds)
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
        if let liveSession {
            liveSession.togglePlayback()
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
        liveSession?.stop()
        liveSession = nil
        cancelPlaybackRecovery()
        resetSecondarySubtitles()
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
        mediaID = nil
        playing = false
        danmaku.configure(cid: nil)
        duration = 0
        buffering = false
    }

}
