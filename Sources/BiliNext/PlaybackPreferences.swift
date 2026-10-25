import Foundation

/// A validated snapshot of playback defaults. Existing tabs keep their current speed.
struct PlaybackPreferences {
    static let qualityOptions = [
        (id: 16, title: "360P"), (id: 32, title: "480P"), (id: 64, title: "720P"),
        (id: 80, title: "1080P"), (id: 120, title: "4K"),
    ]
    static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3]
    static let seekSteps: [Double] = [3, 5, 10, 15, 30, 60]
    static let holdRates: [Double] = [1.5, 2, 2.5, 3]

    let quality: Int
    let rate: Double
    let seekStep: Double
    let holdRate: Double
    let autoplayOnTabSelection: Bool

    static var current: PlaybackPreferences { PlaybackPreferences() }

    init(defaults: UserDefaults = .standard) {
        autoplayOnTabSelection = defaults.bool(forKey: Preferences.autoplayOnTabSelection)
        let storedQuality = defaults.integer(forKey: Preferences.defaultQuality)
        quality = Self.qualityOptions.contains { $0.id == storedQuality } ? storedQuality : 80
        func choice(_ key: String, in options: [Double], fallback: Double) -> Double {
            let value = defaults.double(forKey: key)
            return options.contains(value) ? value : fallback
        }
        rate = choice(Preferences.defaultRate, in: Self.rates, fallback: 1)
        seekStep = choice(Preferences.seekStep, in: Self.seekSteps, fallback: 5)
        holdRate = choice(Preferences.holdRate, in: Self.holdRates, fallback: 2)
    }
}
