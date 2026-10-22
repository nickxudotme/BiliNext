import Combine
import Foundation
import Testing

@testable import BiliNext

@MainActor
@Test func gridScrollBurstStopsPreviewOnceAndSettlesAfterIdle() async throws {
    let interaction = VideoGridInteraction()
    var stops = 0
    interaction.beginScrolling { stops += 1 }
    interaction.beginScrolling { stops += 1 }
    #expect(interaction.scrolling && stops == 1)
    try await Task.sleep(for: .milliseconds(250))
    #expect(!interaction.scrolling)
    interaction.beginScrolling { stops += 1 }
    #expect(interaction.scrolling && stops == 2)
    interaction.finishScrolling()
}

@MainActor
@Test func gridIdleCancellationDoesNotPublishUntilTheDeferredPageReset() async throws {
    let interaction = VideoGridInteraction()
    interaction.beginScrolling {}
    var publications = 0
    let subscription = interaction.objectWillChange.sink { publications += 1 }
    interaction.cancelIdle()
    #expect(publications == 0 && interaction.scrolling)
    try await Task.sleep(for: .milliseconds(250))
    #expect(publications == 0 && interaction.scrolling)
    interaction.finishScrolling()
    interaction.finishScrolling()
    #expect(publications == 1 && !interaction.scrolling)
    withExtendedLifetime(subscription) {}
}
