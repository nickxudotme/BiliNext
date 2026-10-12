import BiliNextCore
import SwiftUI

struct SubtitleOverlay: View {
    let primary: [Cue]
    let secondary: [Cue]
    let time: Double
    @AppStorage("player.subtitle.removeLineBreaks") private var removeLineBreaks = false

    private static func text(_ cues: [Cue], time: Double, removeLineBreaks: Bool) -> String {
        cues.filter { $0.contains(time) }.map { cue in
            guard removeLineBreaks else { return cue.text }
            return cue.text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func lines(
        primary: [Cue], secondary: [Cue], time: Double, removeLineBreaks: Bool = false
    ) -> [String] {
        [
            text(primary, time: time, removeLineBreaks: removeLineBreaks),
            text(secondary, time: time, removeLineBreaks: removeLineBreaks),
        ].filter { !$0.isEmpty }
    }

    var body: some View {
        let main = Self.text(primary, time: time, removeLineBreaks: removeLineBreaks)
        let second = Self.text(secondary, time: time, removeLineBreaks: removeLineBreaks)
        if !main.isEmpty || !second.isEmpty {
            VStack(spacing: 4) {
                if !main.isEmpty {
                    Text(main).font(.system(size: 18, weight: .medium)).foregroundStyle(.white)
                }
                if !second.isEmpty {
                    Text(second).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
