import Foundation
import Testing

@testable import BiliNext

@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

@MainActor
@Test func tabPreviewWaitsOnceThenFollowsNeighboursUntilThePointerLeaves() async throws {
    let preview = TabHoverPreview(delay: .milliseconds(60), grace: .milliseconds(30))
    preview.hover("A", inside: true)
    #expect(preview.tabID == nil)
    #expect(try await eventually { preview.tabID == "A" })

    // Crossing to a neighbour: leave A, enter B, without waiting again.
    preview.hover("A", inside: false)
    preview.hover("B", inside: true)
    #expect(preview.tabID == "B")

    preview.hover("B", inside: false)
    #expect(try await eventually { preview.tabID == nil })

    // After leaving, the next hover waits for the delay again, and dismissing cancels it.
    preview.hover("C", inside: true)
    #expect(preview.tabID == nil)
    preview.dismiss()
    try await Task.sleep(for: .milliseconds(150))
    #expect(preview.tabID == nil)
}
