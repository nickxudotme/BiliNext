import BiliNextCore
import Foundation

extension AppModel {
    // MARK: - Likes, coins, favorites and 一键三连

    /// Reads the account's state for the open video; anonymous viewers keep the defaults.
    func loadRelation(for bvid: String) {
        relation = VideoRelation()
        relationLoaded = false
        guard profile != nil else { return }
        let account = accountGeneration
        Task {
            do {
                let state = try await api.videoRelation(bvid: bvid)
                guard account == accountGeneration, detail?.video.bvid == bvid else { return }
                relation = state
                relationLoaded = true
            } catch {
                guard detail?.video.bvid == bvid else { return }
                toast = "互动状态加载失败：" + error.localizedDescription
            }
        }
    }

    /// Account writes only start here, from the user's click or shortcut.
    func toggleLike() {
        guard let video = interactiveVideo() else { return }
        let desired = !relation.liked
        interactionBusy = true
        Task {
            defer { interactionBusy = false }
            do {
                try await api.likeVideo(bvid: video.bvid, liked: desired)
                relation.liked = desired
                adjustStats { $0.likes = $0.likes.map { $0 + (desired ? 1 : -1) } }
            } catch { toast = error.localizedDescription }
        }
    }

    func requestCoin() {
        guard interactiveVideo() != nil, relation.coins < 2 else { return }
        coinDialogPresented = true
    }

    func coin(_ count: Int) {
        guard let video = interactiveVideo() else { return }
        interactionBusy = true
        Task {
            defer { interactionBusy = false }
            do {
                try await api.coinVideo(bvid: video.bvid, count: count)
                relation.coins += count
                adjustStats { $0.coins = $0.coins.map { $0 + count } }
                toast = "已投 \(count) 枚硬币"
            } catch { toast = error.localizedDescription }
        }
    }

    func requestFavorite() {
        guard interactiveVideo()?.aid != nil else { return }
        favoritePresented = true
    }

    func triple() {
        guard let video = interactiveVideo(), let aid = video.aid else { return }
        interactionBusy = true
        let before = relation
        Task {
            defer { interactionBusy = false }
            do {
                let result = try await api.tripleVideo(aid: aid)
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
            } catch { toast = error.localizedDescription }
        }
    }

    /// The open, non-episode video, or nil after asking an anonymous viewer to log in.
    private func interactiveVideo() -> Video? {
        guard let video = detail?.video, video.episodeID == nil, !interactionBusy else {
            return nil
        }
        guard profile != nil else {
            loginPresented = true
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
