import SwiftUI

/// UserDefaults keys for preferences shown in 设置.
enum Preferences {
    static let autoExpandIntro = "intro.autoExpand"
    static let hoverPrefetch = "playback.hoverPrefetch"
}

/// The app's 设置 window (⌘,).
struct SettingsView: View {
    @AppStorage(Preferences.autoExpandIntro) private var autoExpandIntro = false
    @AppStorage(Preferences.hoverPrefetch) private var hoverPrefetch = false

    var body: some View {
        Form {
            Section("播放") {
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
