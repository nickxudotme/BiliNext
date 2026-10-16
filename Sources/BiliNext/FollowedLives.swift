import BiliNextCore
import Combine
import Foundation

@MainActor
final class FollowedLives: ObservableObject {
    @Published private(set) var rooms: [LiveRoom] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let load: () async throws -> [LiveRoom]
    private(set) var task: Task<Void, Never>?
    private var generation = UUID()

    convenience init(api: BilibiliAPI) {
        self.init(load: { try await api.followedLiveRooms() })
    }

    init(load: @escaping () async throws -> [LiveRoom]) { self.load = load }

    func reset() {
        generation = UUID()
        task?.cancel()
        task = nil
        rooms = []
        loading = false
        error = nil
    }

    func refresh() {
        task?.cancel()
        let request = UUID()
        generation = request
        loading = true
        error = nil
        task = Task {
            do {
                let result = try await load()
                guard !Task.isCancelled, generation == request else { return }
                rooms = result
            } catch {
                guard !Task.isCancelled, generation == request else { return }
                self.error = error.localizedDescription
            }
            if generation == request { loading = false }
        }
    }
}
