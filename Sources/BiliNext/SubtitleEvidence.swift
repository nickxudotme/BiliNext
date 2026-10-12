import Foundation
import NaturalLanguage

struct SubtitleEvidence: Sendable {
    enum Finding: Equatable { case uncertain, duplicate, differentLanguage }
    private var duplicates = Set<String>()
    private var translations = Set<String>()
    private var translatedHard = Set<String>()
    private var lastTime: Double?

    mutating func observe(soft: String, hard: [String], time: Double) -> Finding {
        // Seeking invalidates accumulated evidence; repeated frames of one cue do not count.
        if let lastTime, time < lastTime || time - lastTime > 15 {
            duplicates = []
            translations = []
            translatedHard = []
        }
        lastTime = time
        let softKey = Self.normalize(soft)
        guard softKey.count >= 4 else { return .uncertain }
        if hard.contains(where: { Self.matches(soft, $0) }) {
            duplicates.insert(softKey)
            translations = []
            translatedHard = []
        } else if let language = Self.language(soft),
            let otherText = hard.first(where: {
                guard Self.normalize($0).count >= 4, let other = Self.language($0) else {
                    return false
                }
                return language != other
            })
        {
            duplicates = []
            translations.insert(softKey)
            translatedHard.insert(Self.normalize(otherText))
        } else {
            duplicates = []
            translations = []
            translatedHard = []
        }
        if duplicates.count >= 3 { return .duplicate }
        if translations.count >= 3 && translatedHard.count >= 3 { return .differentLanguage }
        return .uncertain
    }

    static func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil
        )
        .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init).joined()
    }

    static func matches(_ soft: String, _ hard: String) -> Bool {
        let a = Array(normalize(soft))
        let b = Array(normalize(hard))
        guard min(a.count, b.count) >= 4 else { return false }
        // Allow modest OCR errors, without treating a short sign within a long cue as a match.
        guard Double(min(a.count, b.count)) / Double(max(a.count, b.count)) >= 0.75 else {
            return false
        }
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var row = [i + 1]
            for (j, other) in b.enumerated() {
                row.append(
                    min(row[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1))
                )
            }
            previous = row
        }
        return Double(previous[b.count]) / Double(max(a.count, b.count)) <= 0.18
    }

    static func language(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
            confidence >= 0.8
        else { return nil }
        if language == .simplifiedChinese || language == .traditionalChinese { return "zh" }
        return language.rawValue
    }
}
