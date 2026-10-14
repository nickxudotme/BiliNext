import BiliNextCore
import SwiftUI

/// UserDefaults keys for preferences shown in 设置.
enum Preferences {
    static let autoExpandIntro = "intro.autoExpand"
    static let hoverPrefetch = "playback.hoverPrefetch"
    static let cdnMirror = "playback.cdnMirror"

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

    var body: some View {
        Form {
            Section("播放") {
                Picker(selection: $cdnMirror) {
                    Text("按 B 站分配").tag("auto")
                    ForEach(CDNPreference.mirrors, id: \.id) { Text($0.title).tag($0.id) }
                } label: {
                    Text("CDN 镜像")
                    Text("视频从固定的官方镜像开始加载，该镜像不可用时自动换回 B 站分配的地址。固定镜像的域名常驻缓存，开播不必等待 DNS。")
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
        .navigationTitle("设置")
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
