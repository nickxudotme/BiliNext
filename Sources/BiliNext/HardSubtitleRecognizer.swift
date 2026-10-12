import Foundation
import Vision

struct HardSubtitleRecognizer {
    static func recognize(_ frame: SubtitleFrame) throws -> [String] {
        guard let image = frame.image else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        // Vision uses a bottom-left origin. Restrict OCR to likely subtitle lines.
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.4)
        try VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).filter {
            $0.boundingBox.width >= 0.1 && $0.boundingBox.height >= 0.012
                && $0.boundingBox.height <= 0.35
        }.compactMap { observation -> String? in
            guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.65
            else { return nil }
            return candidate.string
        }
        return lines + (lines.count > 1 ? [lines.joined()] : [])
    }
}
