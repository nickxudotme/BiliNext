import Foundation
import Testing

@testable import BiliNext

private func preferenceStore() throws -> (UserDefaults, String) {
    let name = "BiliNext.PlaybackPreferencesTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

@Test func playbackDefaultsPreserveExistingBehavior() throws {
    let (defaults, name) = try preferenceStore()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = PlaybackPreferences(defaults: defaults)
    #expect(preferences.quality == 80 && preferences.rate == 1)
    #expect(preferences.seekStep == 5 && preferences.holdRate == 2)
    #expect(!preferences.autoplayOnTabSelection)
}

@Test func playbackDefaultsPersistAndKeepQualityPrefetchesSeparate() throws {
    let (defaults, name) = try preferenceStore()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(120, forKey: Preferences.defaultQuality)
    defaults.set(1.5, forKey: Preferences.defaultRate)
    defaults.set(15, forKey: Preferences.seekStep)
    defaults.set(3, forKey: Preferences.holdRate)
    defaults.set(true, forKey: Preferences.autoplayOnTabSelection)
    let first = PlaybackPreferences(defaults: defaults)
    #expect(first.quality == 120 && first.rate == 1.5)
    #expect(first.seekStep == 15 && first.holdRate == 3)
    #expect(first.autoplayOnTabSelection)
    defaults.set(64, forKey: Preferences.defaultQuality)
    let second = PlaybackPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(second.quality == 64)
    // A quality change must not consume a URL prefetched for the previous setting.
    let key = PlaybackPrefetch.Key.current(bvid: "BV1", cid: 1, preferences: first)
    let changed = PlaybackPrefetch.Key.current(bvid: "BV1", cid: 1, preferences: second)
    #expect(key != changed && key.quality == 120 && changed.quality == 64)
    let explicit = PlaybackPrefetch.Key.current(
        bvid: "BV1", cid: 1, quality: 80, preferences: second)
    #expect(explicit.quality == 80)
}

@Test func corruptPlaybackDefaultsFallBackWithoutAffectingOtherChoices() throws {
    let (defaults, name) = try preferenceStore()
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(-1, forKey: Preferences.defaultQuality)
    defaults.set("invalid", forKey: Preferences.defaultRate)
    defaults.set(-10, forKey: Preferences.seekStep)
    defaults.set(300, forKey: Preferences.holdRate)
    let preferences = PlaybackPreferences(defaults: defaults)
    #expect(preferences.quality == 80 && preferences.rate == 1)
    #expect(preferences.seekStep == 5 && preferences.holdRate == 2)
    defaults.set(0.75, forKey: Preferences.defaultRate)
    #expect(PlaybackPreferences(defaults: defaults).rate == 0.75)
}
