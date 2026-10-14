import BiliNextCore
import SwiftUI

/// UserDefaults keys for preferences shown in 设置.
enum Preferences {
    static let autoExpandIntro = "intro.autoExpand"
    static let hoverPrefetch = "playback.hoverPrefetch"
    static let cdnMirror = "playback.cdnMirror"
    static let preferredCodec = "playback.preferredCodec"
    static let prefersLossless = "playback.losslessAudio"
    static let endActionKey = "playback.endAction"

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
    @AppStorage(Preferences.autoExpandIntro) private var autoExpandIntro = false
    @AppStorage(Preferences.hoverPrefetch) private var hoverPrefetch = false
    @AppStorage(Preferences.cdnMirror) private var cdnMirror = "ali"
    @AppStorage(Preferences.preferredCodec) private var preferredCodec = "av1"
    @AppStorage(Preferences.prefersLossless) private var losslessAudio = true
    @AppStorage(Preferences.endActionKey) private var endAction = PlaybackEndAction.next.rawValue

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { general }
            Tab("快捷键", systemImage: "keyboard") { ShortcutList() }
        }
        .navigationTitle("设置")
        .frame(width: 520)
    }

    private var general: some View {
        Form {
            Section("播放") {
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
            Section("视频简介") {
                Toggle(isOn: $autoExpandIntro) {
                    Text("自动展开详情")
                    Text("打开视频时直接显示完整标题、简介、标签和稿件编号。")
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Every keyboard shortcut, so the official-style single keys can be discovered.
private struct ShortcutList: View {
    private static let player: [(String, String)] = [
        ("空格", "播放 / 暂停"),
        ("← →", "后退 / 前进 5 秒，按住 → 两倍速"),
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
            Section("播放时") { rows(Self.player) }
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
