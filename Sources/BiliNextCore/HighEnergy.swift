import Foundation

/// The 高能进度条: viewer activity sampled every `stepSeconds` across a video.
public struct HighEnergyCurve: Equatable, Sendable {
    public let stepSeconds: Double
    public let samples: [Double]

    public init(stepSeconds: Double, samples: [Double]) {
        self.stepSeconds = stepSeconds
        self.samples = samples
    }

    /// Returns nil unless the response carries a non-empty pbp module.
    public static func parse(_ body: [String: Any]) -> HighEnergyCurve? {
        for module in body["modules"] as? [[String: Any]] ?? [] {
            guard module["load_mode"] as? String == "pbp",
                let data = (module["params"] as? [String: Any])?["data"] as? [String: Any],
                let step = (data["step_sec"] as? NSNumber)?.doubleValue, step > 0,
                let values = (data["events"] as? [String: Any])?["default"] as? [NSNumber],
                values.count > 1
            else { continue }
            return HighEnergyCurve(stepSeconds: step, samples: values.map(\.doubleValue))
        }
        return nil
    }
}
