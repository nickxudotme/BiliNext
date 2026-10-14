import BiliNextCore
import Foundation

extension AppModel {
    // MARK: - Likes, coins, favorites and 一键三连

    /// Reads the account's state for the open video; anonymous viewers keep the defaults.
    /// Rereading the same video keeps the shown state until the answer arrives, and any
    /// write started meanwhile makes that answer stale.
    func loadRelation(for bvid: String) {
        let generation = UUID()
        relationGeneration = generation
        if relationVideo != bvid {
            relationVideo = bvid
            relation = VideoRelation()
            relationLoaded = false
        }
        guard profile != nil else { return }
        let account = accountGeneration
        relationReading = true
        Task {
            defer { if generation == relationGeneration { relationReading = false } }
            do {
                let state = try await api.videoRelation(bvid: bvid)
                guard generation == relationGeneration, account == accountGeneration,
                    relationVideo == bvid
                else { return }
                relation = state
                relationLoaded = true
            } catch {
                guard generation == relationGeneration, relationVideo == bvid else { return }
                toast = "互动状态加载失败：" + error.localizedDescription
            }
        }
    }

    /// Account writes only start here, from the user's click or shortcut.
    func toggleLike() {
        guard let video = writableVideo(allowEpisodes: false) else { return }
        let desired = !relation.liked
        write(video) {
            try await self.api.likeVideo(bvid: video.bvid, liked: desired)
            return {
                self.relation.liked = desired
                self.adjustStats { $0.likes = $0.likes.map { $0 + (desired ? 1 : -1) } }
            }
        }
    }

    func requestCoin() {
        guard writableVideo(allowEpisodes: false) != nil, relation.coins < 2 else { return }
        coinDialogPresented = true
    }

    func coin(_ count: Int) {
        guard let video = writableVideo(allowEpisodes: false) else { return }
        write(video) {
            try await self.api.coinVideo(bvid: video.bvid, count: count)
            return {
                self.relation.coins += count
                self.adjustStats { $0.coins = $0.coins.map { $0 + count } }
                self.toast = "已投 \(count) 枚硬币"
            }
        }
    }

    /// Episodes can be favorited too; only likes, coins and 一键三连 are video-only.
    func requestFavorite() {
        guard writableVideo(allowEpisodes: true, needsRelation: false)?.aid != nil else { return }
        favoritePresented = true
    }

    /// G: follows the uploader, as in the official player. Never unfollows from a key.
    func followUploader() {
        guard let video = writableVideo(allowEpisodes: false), let mid = video.ownerID else {
            return
        }
        guard !relation.following else {
            toast = "已关注 \(video.author)"
            return
        }
        write(video) {
            try await self.api.setFollowing(mid: mid, true)
            return {
                self.relation.following = true
                self.toast = "已关注 \(video.author)"
            }
        }
    }

    /// T: adds the playing video to 稍后再看.
    func addPlayingToWatchLater() {
        guard let video = detail?.video, video.episodeID == nil else { return }
        guard profile != nil else {
            loginPresented = true
            return
        }
        changeWatchLater(video)
    }

    func triple() {
        guard let video = writableVideo(allowEpisodes: false), let aid = video.aid else { return }
        let before = relation
        write(video) {
            let result = try await self.api.tripleVideo(aid: aid)
            return { self.applyTriple(result, before: before) }
        }
    }

    private func applyTriple(_ result: VideoRelation, before: VideoRelation) {
        relation.liked = before.liked || result.liked
        relation.coins = max(before.coins, result.coins)
        relation.favorited = before.favorited || result.favorited
        adjustStats { stats in
            if result.liked && !before.liked { stats.likes = stats.likes.map { $0 + 1 } }
            if result.coins > before.coins {
                stats.coins = stats.coins.map { $0 + result.coins - before.coins }
            }
            if result.favorited && !before.favorited {
                stats.favorites = stats.favorites.map { $0 + 1 }
            }
        }
        tripleCount += 1
        toast = "三连成功"
    }

    /// Runs one write. Starting it discards any read still in flight; the returned update
    /// is applied only while the same video is still open.
    private func write(
        _ video: Video, _ perform: @escaping () async throws -> (@MainActor () -> Void)
    ) {
        relationGeneration = UUID()
        relationReading = false
        interactionBusy = true
        Task {
            defer { interactionBusy = false }
            do {
                let apply = try await perform()
                if relationVideo == video.bvid { apply() }
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    /// The open video when a write may start: signed in, not busy, and (for toggles that
    /// depend on it) with the account's current state already read.
    private func writableVideo(allowEpisodes: Bool, needsRelation: Bool = true) -> Video? {
        guard let video = detail?.video, allowEpisodes || video.episodeID == nil,
            !interactionBusy
        else { return nil }
        guard profile != nil else {
            loginPresented = true
            return nil
        }
        if needsRelation && !(relationLoaded && relationVideo == video.bvid) {
            toast = "正在读取互动状态，请稍候"
            if !relationReading { loadRelation(for: video.bvid) }
            return nil
        }
        return video
    }

    private func adjustStats(_ change: (inout VideoStats) -> Void) {
        guard var current = detail else { return }
        change(&current.stats)
        detail = current
    }
}
