import BiliNextCore
import Observation
import Testing

@testable import BiliNext

@MainActor
@Test func transcriptIndexKeepsGroupingStableAcrossSearchAndPlayback() {
    let index = TranscriptIndex()
    let cues = [
        Cue(id: 7, start: 0, end: 2, text: "Hello"),
        Cue(id: 2, start: 1, end: 4, text: "world"),
        Cue(id: 9, start: 10, end: 12, text: "Next"),
    ]
    index.update(cues: cues, paragraphs: true, query: "HELLOworld")
    #expect(index.groups.map { $0.map(\.id) } == [[7, 2], [9]])
    #expect(index.matches == [7])
    #expect(index.activeIDs(at: 1.5) == [7, 2])
    #expect(index.activeGroup(for: [7, 2]) == 7)
    #expect(index.activeIDs(at: 4).isEmpty)
    var regrouped = false
    withObservationTracking {
        _ = index.groups
    } onChange: {
        regrouped = true
    }
    for step in 0..<1000 { _ = index.activeIDs(at: Double(step) / 100) }
    index.update(cues: cues, paragraphs: true, query: "next")
    #expect(index.matches == [9])
    #expect(!regrouped)
    index.update(cues: cues, paragraphs: false, query: "world")
    #expect(regrouped)
    #expect(index.matches == [2])
    #expect(index.activeGroup(for: [2]) == 2)
    index.update(cues: [], paragraphs: false, query: "world")
    #expect(index.groups.isEmpty && index.matches.isEmpty)
    #expect(index.activeIDs(at: 1).isEmpty)
}
