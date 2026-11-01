import BiliNextCore
import Observation

/// Text grouping and search depend on the track and user input, never on timer ticks.
@MainActor @Observable
final class TranscriptIndex {
    private(set) var groups: [[Cue]] = []
    private(set) var matches: [Int] = []
    @ObservationIgnored private var cues: [Cue] = []
    @ObservationIgnored private var paragraphs = false
    @ObservationIgnored private var query = ""
    @ObservationIgnored private var texts: [(id: Int, text: String)] = []
    @ObservationIgnored private var groupForCue: [Int: Int] = [:]

    func update(cues: [Cue], paragraphs: Bool, query: String) {
        let regroup = self.cues != cues || self.paragraphs != paragraphs
        if regroup {
            self.cues = cues
            self.paragraphs = paragraphs
            groups = paragraphs ? Cue.paragraphs(cues) : cues.map { [$0] }
            texts = groups.compactMap { group in
                guard let first = group.first else { return nil }
                return (first.id, group.map(\.text).joined())
            }
            groupForCue = [:]
            for group in groups {
                guard let first = group.first else { continue }
                for cue in group { groupForCue[cue.id] = first.id }
            }
        }
        if regroup || self.query != query {
            self.query = query
            matches =
                query.isEmpty
                ? []
                : texts.compactMap {
                    $0.text.localizedCaseInsensitiveContains(query) ? $0.id : nil
                }
        }
    }

    func activeIDs(at time: Double) -> Set<Int> {
        Set(cues.lazy.filter { $0.contains(time) }.map(\.id))
    }

    func activeGroup(for ids: Set<Int>) -> Int? {
        // Preserve track order for overlapping cues, even when IDs are not sorted.
        cues.first { ids.contains($0.id) }.flatMap { groupForCue[$0.id] }
    }
}
