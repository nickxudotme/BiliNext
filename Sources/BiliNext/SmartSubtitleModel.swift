import BiliNextCore
import Combine
import Foundation

@MainActor
final class SmartSubtitleModel: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "subtitles.smart.enabled")
            redetect()
        }
    }
    @Published var autoShow: Bool {
        didSet {
            defaults.set(autoShow, forKey: "subtitles.smart.autoShow")
            redetect()
        }
    }
    @Published var differentLanguage: String {
        didSet {
            defaults.set(differentLanguage, forKey: "subtitles.smart.languages")
            redetect()
        }
    }
    @Published var channelRule = "auto" {
        didSet {
            saveRule(channelRule, key: channelKey)
            redetect()
        }
    }
    @Published var videoRule = "auto" {
        didSet {
            saveRule(videoRule, key: videoKey)
            redetect()
        }
    }
    @Published private(set) var visible = true
    @Published private(set) var status = "等待可用字幕"
    @Published private(set) var needsDecision = false
    @Published private(set) var checking = false
    private let defaults: UserDefaults
    private var channelKey = ""
    private var videoKey = ""
    private var context = ""
    private var configuring = false
    private var manual = false
    private var evidence = SubtitleEvidence()
    private var lastSample = Date.distantPast
    private var lastCue = ""
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "subtitles.smart.enabled") as? Bool ?? true
        autoShow = defaults.object(forKey: "subtitles.smart.autoShow") as? Bool ?? true
        differentLanguage = defaults.string(forKey: "subtitles.smart.languages") ?? "keep"
        visible = defaults.object(forKey: "player.subtitles") as? Bool ?? true
    }

    func configure(video: String?, cid: Int64?, owner: Int64?, track: String) {
        let next = "\(video ?? ""):\(cid ?? 0):\(owner ?? 0):\(track)"
        guard context != next else { return }
        context = next
        configuring = true
        channelKey = owner.map { "subtitles.smart.channel.\($0)" } ?? ""
        videoKey = video.map { "subtitles.smart.video.\($0).\(cid ?? 0).\(track)" } ?? ""
        channelRule = defaults.string(forKey: channelKey) ?? "auto"
        videoRule = defaults.string(forKey: videoKey) ?? "auto"
        configuring = false
        redetect()
    }

    private func saveRule(_ value: String, key: String) {
        guard !configuring, !key.isEmpty else { return }
        if value == "auto" {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
    }

    var hasChannel: Bool { !channelKey.isEmpty }
    private var rule: String { videoRule == "auto" ? channelRule : videoRule }

    func redetect() {
        guard !configuring else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        checking = false
        manual = false
        needsDecision = false
        evidence = SubtitleEvidence()
        lastSample = .distantPast
        lastCue = ""
        visible =
            rule == "hide"
            ? false
            : rule == "show" || (enabled && autoShow)
                ? true : defaults.object(forKey: "player.subtitles") as? Bool ?? true
        status =
            rule == "auto" ? (enabled ? "等待画面检测" : "自动检测已关闭") : (visible ? "按规则保留软字幕" : "按规则隐藏软字幕")
    }

    func setVisible(_ value: Bool) {
        generation = UUID()
        task?.cancel()
        task = nil
        checking = false
        visible = value
        manual = true
        needsDecision = false
        defaults.set(value, forKey: "player.subtitles")
        status = value ? "本次观看保留软字幕" : "本次观看隐藏软字幕"
    }

    func resetAfterSeek() {
        generation = UUID()
        task?.cancel()
        task = nil
        checking = false
        evidence = SubtitleEvidence()
        lastCue = ""
        lastSample = .distantPast
        if !manual && rule == "auto" && enabled {
            visible = true
            needsDecision = false
            status = "等待画面检测"
        }
    }

    func resolveLanguage(keep: Bool) {
        setVisible(keep)
    }

    func updateAvailability(hasCues: Bool, loading: Bool) {
        guard rule == "auto", !manual, !checking, !needsDecision, lastCue.isEmpty else { return }
        let next = hasCues ? (enabled ? "等待画面检测" : "自动检测已关闭") : (loading ? "等待字幕加载" : "没有可用软字幕")
        if status != next { status = next }
    }

    func sample(player: MPVPlayer?, cues: [Cue], time: Double, active: Bool) {
        guard enabled, rule == "auto", !manual, visible, !needsDecision,
            active, task == nil,
            Date().timeIntervalSince(lastSample) >= 4,
            let player, player.loaded
        else { return }
        let soft = cues.filter { $0.contains(time) }.map(\.text).joined(separator: "\n")
        guard !soft.isEmpty, soft != lastCue else { return }
        lastSample = Date()
        lastCue = soft
        checking = true
        let token = generation
        task = Task { [weak self] in
            let frame = await player.subtitleFrame()
            guard !Task.isCancelled, let self, token == self.generation else { return }
            let sampledTime = player.time
            guard
                cues.filter({ $0.contains(sampledTime) }).map(\.text).joined(separator: "\n")
                    == soft
            else {
                self.checking = false
                self.task = nil
                self.lastCue = ""
                return
            }
            do {
                let hard = try await Task.detached(priority: .utility) {
                    try frame.map(HardSubtitleRecognizer.recognize) ?? []
                }.value
                guard !Task.isCancelled, token == self.generation else { return }
                switch self.evidence.observe(soft: soft, hard: hard, time: sampledTime) {
                case .duplicate:
                    self.visible = false
                    self.status = "检测到重复字幕，已隐藏软字幕"
                case .differentLanguage:
                    if self.differentLanguage == "hide" {
                        self.visible = false
                        self.status = "画面字幕语言不同，已按设置隐藏"
                    } else if self.differentLanguage == "ask" {
                        self.needsDecision = true
                        self.status = "画面字幕语言不同，请选择是否保留"
                    } else {
                        self.status = "画面字幕语言不同，保留软字幕"
                    }
                case .uncertain:
                    self.status = frame == nil ? "暂时无法取样，保留软字幕" : "证据不足，保留软字幕并继续检测"
                }
            } catch {
                guard token == self.generation else { return }
                self.status = "识别暂不可用，保留软字幕"
            }
            self.checking = false
            self.task = nil
        }
    }
}
