import BiliNextCore
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func toastClearsItselfWithoutAView() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(
        sessionStore: SessionStore(directory: directory), api: BilibiliAPI(restoreSession: false))
    model.toast = "已加入稍后再看"
    try await Task.sleep(for: .seconds(1))
    // Setting the same notice again restarts its timer.
    model.toast = "已加入稍后再看"
    try await Task.sleep(for: .seconds(2))
    #expect(model.toast == "已加入稍后再看")
    try await Task.sleep(for: .seconds(1))
    #expect(model.toast == nil)
}
