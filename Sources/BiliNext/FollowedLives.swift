import BiliNextCore
import Combine
import Foundation

@MainActor
final class FollowedLives: ObservableObject {
    @Published private(set) var rooms: [LiveRoom] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private let api: BilibiliAPI
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(api: BilibiliAPI) { self.api = api }

    func refresh() {
        task?.cancel()
        let request = UUID()
        generation = request
        loading = true
        error = nil
        task = Task {
            do {
                let result = try await api.followedLiveRooms()
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
