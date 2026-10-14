import SwiftUI

/// UserDefaults keys for preferences shown in 设置.
enum Preferences {
    static let autoExpandIntro = "intro.autoExpand"
}

/// The app's 设置 window (⌘,).
struct SettingsView: View {
    @AppStorage(Preferences.autoExpandIntro) private var autoExpandIntro = false

    var body: some View {
        Form {
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
