import BiliNextCore
import Foundation

extension AppModel {
    /// Opens an uploader's space page as its own sidebar tab.
    func openSpace(mid: Int64, name: String, avatar: URL? = nil, background: Bool = false) {
        guard mid > 0 else { return }
        open(
            Video(
                bvid: MemberSpace.tabID(mid), title: name, author: name, avatar: avatar,
                ownerID: mid),
            background: background)
    }

    func activateSpace(_ mid: Int64, force: Bool) {
        selected = MemberSpace.tabID(mid)
        if let memberSpace, memberSpace.mid == mid, !force { return }
        stopMedia()
        let space = MemberSpace(api: api, mid: mid)
        memberSpace = space
        space.onError = { [weak self] in self?.toast = $0 }
        space.onCard = { [weak self] card in
            guard let self else { return }
            let video = Video(
                bvid: MemberSpace.tabID(mid), title: card.name, author: card.name,
                avatar: card.avatar, ownerID: mid)
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
        space.load()
    }
}
