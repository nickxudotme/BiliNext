import BiliNextCore
import Foundation

extension AppModel {
    func openLive(_ room: LiveRoom) {
        open(
            Video(
                bvid: "live:\(room.id)", title: room.title, author: room.author,
                cover: URL(string: room.cover), avatar: URL(string: room.avatar)))
    }

    func activateLive(_ roomID: Int64, force: Bool, autoplay: Bool) {
        selected = "live:\(roomID)"
        if let liveSession, liveSession.requestedRoomID == roomID, !force {
            liveSession.setActive(playbackTabActive, autoplay: autoplay)
            return
        }
        stopMedia()
        let session = LiveSession(api: api, roomID: roomID)
        liveSession = session
        session.onPlaying = { [weak self] in self?.playing = $0 }
        session.onRoom = { [weak self] room in
            guard let self else { return }
            let video = Video(
                bvid: "live:\(roomID)", title: room.title, author: room.author,
                cover: URL(string: room.cover), avatar: URL(string: room.avatar))
            if let index = tabs.firstIndex(where: { $0.id == video.id }) {
                tabs[index].video = video
            }
            if let owner = tabOwner,
                let index = owner.tabs.firstIndex(where: { $0.id == video.id })
            {
                owner.tabs[index].video = video
                owner.saveSession()
            }
        }
        session.setActive(playbackTabActive, autoplay: autoplay)
        session.reload()
    }
}
