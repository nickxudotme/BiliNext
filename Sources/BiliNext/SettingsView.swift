import BiliNextCore
import SwiftUI

/// UserDefaults keys for preferences shown in 设置.
enum Preferences {
    static let autoExpandIntro = "intro.autoExpand"
    static let expandComments = "comments.alwaysExpand"
    static let hoverPrefetch = "playback.hoverPrefetch"
    static let cdnMirror = "playback.cdnMirror"
    static let preferredCodec = "playback.preferredCodec"
    static let prefersLossless = "playback.losslessAudio"
    static let endActionKey = "playback.endAction"
    static let defaultQuality = "playback.defaultQuality"
    static let defaultRate = "playback.defaultRate"
    static let seekStep = "playback.seekStep"
    static let holdRate = "playback.holdRate"

    static var endAction: PlaybackEndAction {
        PlaybackEndAction(rawValue: UserDefaults.standard.string(forKey: endActionKey) ?? "")
            ?? .next
    }

    static var codecOrder: [VideoCodec] {
        VideoCodec.order(
            preferring: VideoCodec(
                rawValue: UserDefaults.standard.string(forKey: preferredCodec) ?? "") ?? .av1)
    }

    /// On unless turned off: Hi-Res and Dolby tracks come only with the account's entitlement.
    static var losslessAudio: Bool {
        UserDefaults.standard.object(forKey: prefersLossless) as? Bool ?? true
    }

    /// The mirror streams start on, or nil to keep Bilibili's assignment (official first).
    static var mirrorHost: String? {
        CDNPreference.host(forMirror: UserDefaults.standard.string(forKey: cdnMirror) ?? "ali")
    }
}

/// The app's 设置 window (⌘,).
struct SettingsView: View {
    @AppStorage("developer.performanceHUD") private var performanceHUD = false
    @AppStorage(Preferences.autoExpandIntro) private var autoExpandIntro = false
    @AppStorage(Preferences.expandComments) private var expandComments = false
    @AppStorage(Preferences.hoverPrefetch) private var hoverPrefetch = false
    @AppStorage(Preferences.cdnMirror) private var cdnMirror = "ali"
    @AppStorage(Preferences.preferredCodec) private var preferredCodec = "av1"
    @AppStorage(Preferences.prefersLossless) private var losslessAudio = true
    @AppStorage(Preferences.endActionKey) private var endAction = PlaybackEndAction.next.rawValue
    @AppStorage(Preferences.defaultQuality) private var defaultQuality = 80
    @AppStorage(Preferences.defaultRate) private var defaultRate = 1.0
    @AppStorage(Preferences.seekStep) private var seekStep = 5.0
    @AppStorage(Preferences.holdRate) private var holdRate = 2.0

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { general }
            Tab("快捷键", systemImage: "keyboard") { ShortcutList() }
            Tab("开发者", systemImage: "wrench.and.screwdriver") {
                Form {
                    Section("性能诊断") {
                        Toggle("显示性能监测浮层", isOn: $performanceHUD)
                        Text("显示近 2 秒的显示回调频率、间隔与迟到情况。每秒更新两次，关闭后停止采样。")
                        Text("回调频率不是应用实际绘制帧率，也不是视频帧率；超预算次数仅供定位卡顿，不能当作实际丢帧数。精确分析请使用 Instruments。")
                            .foregroundStyle(.secondary)
                        Text("监测本身有少量开销，也可能影响系统的自适应刷新策略。请结合关闭监测时的手感对比。")
                            .foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped).frame(height: 340)
            }
        }
        .navigationTitle("设置")
        .frame(width: 520)
    }

    private var general: some View {
        Form {
            Section("播放") {
                Picker(selection: $defaultQuality) {
                    ForEach(PlaybackPreferences.qualityOptions, id: \.id) {
                        Text($0.title).tag($0.id)
                    }
                } label: {
                    Text("默认清晰度")
                    Text("新打开的视频优先使用此档位，实际清晰度由片源与账号权限决定。")
                }
                Picker(selection: $defaultRate) {
                    ForEach(PlaybackPreferences.rates, id: \.self) {
                        Text(String(format: "%g×", $0)).tag($0)
                    }
                } label: {
                    Text("默认倍速")
                    Text("新打开的视频使用此倍速，已打开的标签保留各自选择。")
                }
                Picker("快进／后退步长", selection: $seekStep) {
                    ForEach(PlaybackPreferences.seekSteps, id: \.self) {
                        Text("\(Int($0)) 秒").tag($0)
                    }
                }
                Picker(selection: $holdRate) {
                    ForEach(PlaybackPreferences.holdRates, id: \.self) {
                        Text(String(format: "%g×", $0)).tag($0)
                    }
                } label: {
                    Text("长按倍速")
                    Text("按住 → 时使用，松开后恢复原来的倍速。")
                }
                Picker(selection: $endAction) {
                    ForEach(PlaybackEndAction.allCases, id: \.self) {
                        Text($0.title).tag($0.rawValue)
                    }
                } label: {
                    Text("播完后")
                    Text("连播时先播下一个分 P，再播合集中的下一集。")
                }
                Picker(selection: $cdnMirror) {
                    Text("按 B 站分配").tag("auto")
                    ForEach(CDNPreference.mirrors, id: \.id) { Text($0.title).tag($0.id) }
                } label: {
                    Text("CDN 镜像")
                    Text("视频从固定的官方镜像开始加载，该镜像不可用时自动换回 B 站分配的地址。固定镜像的域名常驻缓存，开播不必等待 DNS。")
                }
                Picker(selection: $preferredCodec) {
                    Text("AV1").tag("av1")
                    Text("HEVC").tag("hevc")
                    Text("AVC（H.264）").tag("avc")
                } label: {
                    Text("优先视频编码")
                    Text("同一清晰度有多种编码时优先选用。AV1 体积最小；AVC 兼容性最好。解码失败时会自动换用其他编码。")
                }
                Toggle(isOn: $losslessAudio) {
                    Text("优先无损与杜比音轨")
                    Text("视频提供 Hi-Res 无损或杜比全景声时使用（通常需要大会员）。")
                }
                Toggle(isOn: $hoverPrefetch) {
                    Text("悬停时预取播放地址")
                    Text("鼠标在视频卡片上停留时提前请求播放地址，点开后更快开播。会多发一些请求。")
                }
            }
            Section("评论") {
                Toggle(isOn: $expandComments) {
                    Text("始终展开评论")
                    Text("长评论直接显示全文，不再折叠成几行。")
                }
            }
            Section("视频简介") {
                Toggle(isOn: $autoExpandIntro) {
                    Text("自动展开详情")
                    Text("打开视频时直接显示完整标题、简介、标签和稿件编号。")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }
}

/// Every keyboard shortcut, so the official-style single keys can be discovered.
private struct ShortcutList: View {
    @AppStorage(Preferences.seekStep) private var seekStep = 5.0
    @AppStorage(Preferences.holdRate) private var holdRate = 2.0

    private var player: [(String, String)] {
        let step = PlaybackPreferences.seekSteps.contains(seekStep) ? seekStep : 5
        let rate = PlaybackPreferences.holdRates.contains(holdRate) ? holdRate : 2
        return [
            ("空格", "播放 / 暂停"),
            ("← →", "后退 / 前进 \(Int(step)) 秒，按住 → \(String(format: "%g", rate)) 倍速"),
            ("↑ ↓", "音量"),
            ("⇧1  ⇧2", "1 倍速 / 2 倍速"),
            ("[  ]", "上一个 / 下一个分 P"),
            ("F", "全屏"),
            ("D", "弹幕开关"),
            ("M", "静音"),
            ("Q", "点赞，按住一秒一键三连"),
            ("W", "投币"),
            ("E", "收藏"),
            ("G", "关注 UP 主"),
            ("T", "稍后再看"),
        ]
    }
    private static let window: [(String, String)] = [
        ("⌘L", "搜索"),
        ("⌘1 … ⌘9", "切换到第几个标签"),
        ("⌃⇥  ⌃⇧⇥", "下一个 / 上一个标签"),
        ("⌘W", "关闭视频标签"),
        ("⇧⌘T", "恢复关闭的标签"),
        ("⌃⌘S", "固定 / 隐藏侧栏"),
        ("⌥⌘P", "窗口置顶"),
        ("⌥⌘M", "小窗播放"),
        ("⌘J", "下载管理"),
        ("⌘,", "设置"),
    ]

    var body: some View {
        Form {
            Section("播放时") { rows(player) }
            Section("窗口与标签") { rows(Self.window) }
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

    private func rows(_ items: [(String, String)]) -> some View {
        ForEach(items, id: \.0) { key, action in
            LabeledContent(action) {
                Text(key).font(.system(.body, design: .rounded).weight(.medium))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}
