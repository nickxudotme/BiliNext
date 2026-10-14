import BiliNextCore
import Foundation

/// One uploader's space page, held by its sidebar tab like a video or live room.
@MainActor
final class MemberSpace: ObservableObject {
    enum Section: String, CaseIterable {
        case uploads = "投稿"
        case collections = "合集和系列"
    }

    /// Upload orders. 最新发布 uses the public list; the others need the signed search.
    static let orders = [("pubdate", "最新发布"), ("click", "最多播放")]

    let mid: Int64
    @Published private(set) var card: MemberCard?
    @Published private(set) var cardError: String?
    @Published private(set) var pinned: Video?
    @Published private(set) var liveRoom: MemberLiveRoom?
    @Published var section = Section.uploads

    @Published private(set) var uploads: [Video] = []
    @Published private(set) var uploadsLoading = false
    @Published private(set) var uploadsError: String?
    /// Set when the chosen order or search needs a signed-in account. Signed out, Bilibili's
    /// risk control rejects them; BiliNext does not send fabricated fingerprints to get past it.
    @Published private(set) var uploadsNeedLogin = false
    @Published private(set) var uploadsMore = false
    @Published var order = "pubdate"
    @Published var keyword = ""
    /// The search that produced `uploads`, shown as 「…」的投稿.
    @Published private(set) var searched = ""

    @Published private(set) var collections: [MemberCollection] = []
    @Published private(set) var collectionsLoading = false
    @Published private(set) var collectionsLoaded = false
    @Published private(set) var collectionsError: String?
    @Published private(set) var collectionsMore = false

    @Published private(set) var openCollection: MemberCollection?
    @Published private(set) var collectionVideos: [Video] = []
    @Published private(set) var collectionLoading = false
    @Published private(set) var collectionError: String?
    @Published private(set) var collectionMore = false

    @Published private(set) var followBusy = false
    var onCard: ((MemberCard) -> Void)?
    var isSignedIn: () -> Bool = { false }
    var onError: ((String) -> Void)?

    private let api: BilibiliAPI
    private var uploadsPage = 0
    private var collectionsPage = 0
    private var collectionPage = 0
    private var uploadsGeneration = UUID()
    private var collectionGeneration = UUID()

    init(api: BilibiliAPI, mid: Int64) {
        self.api = api
        self.mid = mid
    }

    static func mid(_ tabID: String) -> Int64? {
        guard tabID.hasPrefix("space:"), let value = Int64(tabID.dropFirst(6)), value > 0
        else { return nil }
        return value
    }

    static func tabID(_ mid: Int64) -> String { "space:\(mid)" }

    var url: URL { URL(string: "https://space.bilibili.com/\(mid)")! }

    func load() {
        Task { await loadHeader() }
        loadUploads()
    }

    private func loadHeader() async {
        cardError = nil
        async let card = api.memberCard(mid: mid)
        async let pinned = try? api.memberTopVideo(mid: mid)
        async let live = try? api.memberLiveRoom(mid: mid)
        do {
            let value = try await card
            self.card = value
            onCard?(value)
        } catch {
            cardError = error.localizedDescription
        }
        self.pinned = await pinned ?? nil
        liveRoom = await live ?? nil
    }

    func retryHeader() { Task { await loadHeader() } }

    /// Reloads uploads for the current order and search, or appends the next page.
    func loadUploads(more: Bool = false) {
        guard !more || (uploadsMore && !uploadsLoading) else { return }
        let generation = UUID()
        uploadsGeneration = generation
        let page = more ? uploadsPage + 1 : 1
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let sort = order
        if !more {
            uploads = []
            uploadsMore = false
            searched = query
        }
        uploadsError = nil
        uploadsNeedLogin = false
        let signed = !(sort == "pubdate" && query.isEmpty)
        guard !signed || isSignedIn() else {
            uploadsNeedLogin = true
            uploadsLoading = false
            return
        }
        uploadsLoading = true
        Task {
            do {
                let feed =
                    signed
                    ? try await api.memberVideos(mid: mid, page: page, keyword: query, order: sort)
                    : try await api.memberUploads(mid: mid, page: page)
                guard uploadsGeneration == generation else { return }
                var seen = Set(uploads.map(\.id))
                uploads += feed.videos.filter { seen.insert($0.id).inserted }
                uploadsPage = page
                uploadsMore = feed.next != nil
            } catch {
                guard uploadsGeneration == generation else { return }
                uploadsError = Self.describe(error)
            }
            if uploadsGeneration == generation { uploadsLoading = false }
        }
    }

    func search() {
        loadUploads()
    }

    func clearSearch() {
        keyword = ""
        if !searched.isEmpty { loadUploads() }
    }

    /// Back to the public newest-first list, dropping any search.
    func showLatest() {
        keyword = ""
        order = "pubdate"
        loadUploads()
    }

    func setOrder(_ value: String) {
        guard value != order else { return }
        order = value
        loadUploads()
    }

    func loadCollectionsIfNeeded() {
        guard !collectionsLoaded && !collectionsLoading else { return }
        loadCollections()
    }

    func loadCollections(more: Bool = false) {
        guard !collectionsLoading, !more || collectionsMore else { return }
        let page = more ? collectionsPage + 1 : 1
        collectionsLoading = true
        collectionsError = nil
        Task {
            do {
                let result = try await api.memberCollections(mid: mid, page: page)
                if !more { collections = [] }
                var seen = Set(collections.map(\.id))
                collections += result.collections.filter { seen.insert($0.id).inserted }
                collectionsPage = page
                collectionsMore = result.hasMore
                collectionsLoaded = true
            } catch {
                collectionsError = Self.describe(error)
            }
            collectionsLoading = false
        }
    }

    func open(_ collection: MemberCollection) {
        openCollection = collection
        collectionVideos = []
        collectionMore = false
        loadCollectionVideos()
    }

    func closeCollection() {
        collectionGeneration = UUID()
        openCollection = nil
        collectionVideos = []
        collectionLoading = false
    }

    func loadCollectionVideos(more: Bool = false) {
        guard let collection = openCollection else { return }
        guard !more || (collectionMore && !collectionLoading) else { return }
        let generation = UUID()
        collectionGeneration = generation
        let page = more ? collectionPage + 1 : 1
        collectionLoading = true
        collectionError = nil
        Task {
            do {
                let feed = try await api.collectionVideos(
                    mid: mid, collection: collection, page: page)
                guard collectionGeneration == generation else { return }
                var seen = Set(collectionVideos.map(\.id))
                collectionVideos += feed.videos.filter { seen.insert($0.id).inserted }
                collectionPage = page
                collectionMore = feed.next != nil
            } catch {
                guard collectionGeneration == generation else { return }
                collectionError = Self.describe(error)
            }
            if collectionGeneration == generation { collectionLoading = false }
        }
    }

    /// Follows or unfollows from the user's click.
    func toggleFollow() {
        guard var card, !followBusy else { return }
        let follow = !card.following
        followBusy = true
        Task {
            do {
                try await api.setFollowing(mid: mid, follow)
                card.following = follow
                card.followers += follow ? 1 : -1
                self.card = card
            } catch {
                onError?(error.localizedDescription)
            }
            followBusy = false
        }
    }

    /// Risk control is reported plainly rather than retried.
    static func describe(_ error: Error) -> String {
        if let error = error as? APIError, error.code == -352 || error.code == 412 {
            return "B 站暂时限制了这项请求，请稍后再试。「最新发布」不受影响。"
        }
        return error.localizedDescription
    }
}
