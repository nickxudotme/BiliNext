import BiliNextCore

enum MemberSpaceGridEntry: Equatable, Identifiable {
    case video(Video)
    case collection(MemberCollection)

    var id: String {
        switch self {
        case .video(let video): "video:\(video.id)"
        case .collection(let collection): "collection:\(collection.id)"
        }
    }
}
