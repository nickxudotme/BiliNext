import Testing

@testable import BiliNext

@MainActor
@Test func tabPreviewWaitsOnceThenFollowsNeighboursUntilThePointerLeaves() async throws {
    let preview = TabHoverPreview(delay: .milliseconds(60), grace: .milliseconds(30))
    preview.hover("A", inside: true)
    #expect(preview.tabID == nil)
    try await Task.sleep(for: .milliseconds(120))
    #expect(preview.tabID == "A")

    // Crossing to a neighbour: leave A, enter B, without waiting again.
    preview.hover("A", inside: false)
    preview.hover("B", inside: true)
    #expect(preview.tabID == "B")

    preview.hover("B", inside: false)
    try await Task.sleep(for: .milliseconds(90))
    #expect(preview.tabID == nil)

    // After leaving, the next hover waits for the delay again.
    preview.hover("C", inside: true)
    #expect(preview.tabID == nil)
    preview.dismiss()
    try await Task.sleep(for: .milliseconds(120))
    #expect(preview.tabID == nil)
}
