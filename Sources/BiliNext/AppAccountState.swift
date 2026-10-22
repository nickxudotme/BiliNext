import BiliNextCore
import Combine
import Foundation

/// One account identity and request generation per workspace, shared by its retained pages.
/// AppModel forwards this publisher so existing SwiftUI subscriptions keep working.
@MainActor
final class AppAccountState: ObservableObject {
    @Published private(set) var profile: UserProfile?
    @Published private(set) var generation = UUID()

    func updateProfile(_ profile: UserProfile?) { self.profile = profile }
    func updateGeneration(_ generation: UUID) { self.generation = generation }
}
