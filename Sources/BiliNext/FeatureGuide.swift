import SwiftUI

struct GuideReceipt {
    static let revision = "2026-10-29-client-experience"
    static func claim(defaults: UserDefaults = .standard) -> Bool {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        let edition = version + ":" + revision
        var receipts = defaults.stringArray(forKey: "guide.presentedEditions") ?? []
        guard !receipts.contains(edition) else { return false }
        receipts.append(edition)
        defaults.set(Array(receipts.suffix(32)), forKey: "guide.presentedEditions")
        return true
    }
}

struct FeatureGuideLaunch: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.task {
            guard GuideReceipt.claim() else { return }
            openWindow(id: "guide")
        }
    }
}

struct FeatureGuide: View {
    @State private var updates = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更顺手地使用 BiliNext").font(.title.bold())
            Picker("内容", selection: $updates) {
                Text("使用指南").tag(false)
                Text("本次更新").tag(true)
            }
            .pickerStyle(.segmented)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if updates {
                        section(
                            "播放与性能",
                            "新增播放信息面板，可查看实际解码方式、CDN、下载速度、前向缓冲和丢帧。弹幕空档停止显示调度。人物防挡为默认关闭的可选功能。",
                            "waveform.path.ecg")
                        section(
                            "搜索与评论", "搜索支持用户、时长和发布日期筛选，提供搜索历史与联想。评论里的视频链接显示封面卡片，⌘ 点击可在后台打开。",
                            "magnifyingglass")
                        section(
                            "登录与互动", "新扫码同时保存网页和客户端授权；旧登录继续可用。客户端授权过期时重新扫码。提交结果未确认时先刷新状态，避免重复投币。",
                            "person.crop.circle")
                        section(
                            "下载与恢复", "下载支持分轨合并、暂停与继续。重启后可从下载管理恢复；重新获取地址后会核对媒体身份。缓存和导出的视频分别管理。",
                            "arrow.down.circle")
                    } else {
                        section(
                            "边看边发现",
                            "⌘ 点击视频或评论卡片，在后台打开标签。切换标签默认保持暂停，可在设置中开启自动播放。⌃ Tab 切换标签，⌘⇧T 恢复关闭的标签。",
                            "sidebar.left")
                        section(
                            "播放器", "空格暂停，方向键前后跳转；按住右方向键临时加速。播放页的「…」菜单可打开播放信息和复制诊断。⌥⌘M 切换小窗。",
                            "play.rectangle")
                        section(
                            "字幕阅读", "右侧「字幕」面板可搜索、逐句跳转和复制。双语字幕可以同时选择两条轨道，智能字幕能识别画面中的硬字幕。",
                            "captions.bubble")
                        section(
                            "搜索与下载",
                            "顶部搜索框可输入关键词、BV 号或视频链接。搜索页可切换视频与用户。⌘J 打开下载管理，缓存视频直接在标签页播放。⌘O 打开本地视频。",
                            "magnifyingglass")
                        section(
                            "登录与帮助", "用哔哩哔哩手机客户端扫码并确认。登录保存在本机；关闭扫码窗口会保留原登录。可随时从「帮助」菜单重新打开本指南。",
                            "questionmark.circle")
                    }
                }.padding(.vertical, 8)
            }
        }.padding(28).frame(minWidth: 520, idealWidth: 620, minHeight: 500, idealHeight: 640)
    }
    private func section(_ title: String, _ text: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GuideCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("BiliNext 使用指南与更新说明") { openWindow(id: "guide") }
        }
    }
}
