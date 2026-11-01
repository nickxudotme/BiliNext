import BiliNextCore
import Foundation

/// What happens when a video plays to its end.
enum PlaybackEndAction: String, CaseIterable {
    /// The next 分P, then the next episode of the 合集.
    case next
    /// As `next`, then the first related video.
    case nextOrRelated
    case pause
    case loop

    var title: String {
        switch self {
        case .next: "连播分 P 与合集"
        case .nextOrRelated: "连播并接相关推荐"
        case .pause: "暂停"
        case .loop: "单集循环"
        }
    }
}

extension AppModel {
    /// Moves on when the current media ends, following 设置 · 播完后.
    func playbackEnded() {
        guard liveSession == nil, !officialCore, let detail else { return }
        // EOF pauses the engine. Clear the old intent too, so the visible play button
        // resumes on its first click when there is no next item. Continuing sets it again.
        playbackIntent = false
        switch Preferences.endAction {
        case .pause:
            return
        case .loop:
            seek(0)
            playbackIntent = true
            startBufferedPlayback()
        case .next, .nextOrRelated:
            if let page = Self.nextPage(after: pageID, in: detail.pages) {
                toast = "接着播放 P\(page.number) \(page.title)"
                selectPage(page.cid, autoplay: true)
            } else if let video = Self.nextEpisode(
                after: detail.video.bvid, in: detail.extras.season)
                ?? (Preferences.endAction == .nextOrRelated ? detail.extras.related.first : nil),
                let id = selected
            {
                toast = "接着播放「\(video.title)」"
                replace(id, with: video)
            }
        }
    }

    nonisolated static func nextPage(after cid: Int64?, in pages: [VideoPage]) -> VideoPage? {
        guard let index = pages.firstIndex(where: { $0.cid == cid }), index + 1 < pages.count
        else { return nil }
        return pages[index + 1]
    }

    /// The episode after `bvid` across the 合集's sections, as a video to open.
    nonisolated static func nextEpisode(after bvid: String, in season: VideoSeason?) -> Video? {
        let episodes = season?.sections.flatMap(\.episodes) ?? []
        guard let index = episodes.firstIndex(where: { $0.bvid == bvid }),
            index + 1 < episodes.count
        else { return nil }
        let episode = episodes[index + 1]
        return Video(
            bvid: episode.bvid, title: episode.title, author: episode.author,
            cover: episode.cover, aid: episode.aid, duration: episode.duration,
            viewCount: episode.views.map(String.init), pubdate: episode.pubdate, cid: episode.cid)
    }
}
