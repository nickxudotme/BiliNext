import AppKit
import BiliNextCore
import SwiftUI
import Testing

@testable import BiliNext

/// Pure view fixtures: no account, session store, player or network is created.
@MainActor
@Test func visualPreviewSolidSurfaces() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let originalAppearance = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = originalAppearance }
    for dark in [false, true] {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = VStack(alignment: .leading, spacing: 24) {
            HStack {
                SectionTabs(
                    items: [("推荐", "推荐"), ("热门", "热门"), ("排行榜", "排行榜")],
                    selection: "推荐", glass: true
                ) { _ in }
                Spacer()
                Label("搜索视频", systemImage: "magnifyingglass")
                    .font(GlassTheme.labelFont).padding(10).floatingGlass(in: Capsule())
            }
            .padding(16)
            .background { SoftScrollEdge() }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("侧栏与浮层").font(GlassTheme.sectionTitleFont)
                    Label("动态", systemImage: "rectangle.stack")
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background { NavigationSelection(selected: true) }
                    Label("稍后再看", systemImage: "clock")
                        .padding(10).chromeSurface(in: Capsule())
                }
                .padding(16).frame(width: 240)
                .background { SidebarSurface(pinned: false) }
                VStack(alignment: .leading, spacing: 16) {
                    Text("视频详情").font(GlassTheme.sheetTitleFont)
                    Text("纯色面板保持正文清晰，控件不再采样背后的画面。")
                        .font(GlassTheme.bodyFont)
                    Text("12:46 · 1080P · 1×").font(GlassTheme.metadataFont)
                        .foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Image(systemName: "play.fill")
                        Text("03:27 / 12:46").monospacedDigit()
                        Spacer()
                        Image(systemName: "speaker.wave.2.fill")
                    }
                    .font(GlassTheme.labelFont)
                    .playerGlassBar(compact: true)
                }
                .padding(20).frame(maxWidth: .infinity)
                .floatingGlassPanel().environment(\.colorScheme, .dark)
            }
            .padding(.horizontal, 16)
            ErrorBanner(message: "暂时无法加载视频，请稍后重试。") {}
                .padding(.horizontal, 16)
        }
        .padding(20).frame(width: 880)
        .background(GlassTheme.canvas)
        .environment(\.colorScheme, dark ? .dark : .light)
        try renderPreview(
            view,
            name: "bilinext-solid-\(dark ? "dark" : "light")"
        )
    }
}

/// Opt-in offscreen renders for reviewing shared states without a signed app:
/// `BILINEXT_RENDER_PREVIEW=1 swift test --filter VisualPreview` writes PNGs to the
/// directory in `BILINEXT_RENDER_DIR` (default /tmp). Glass does not render offscreen.
@MainActor
private func renderPreview(_ view: some View, name: String) throws {
    let directory = ProcessInfo.processInfo.environment["BILINEXT_RENDER_DIR"] ?? "/tmp"
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    let tiff = try #require(image.tiffRepresentation)
    let rep = try #require(NSBitmapImageRep(data: tiff))
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
}

@MainActor
@Test func visualPreviewLoadingStates() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let view = VStack(spacing: 20) {
        ErrorBanner(message: "网络电波没能抵达，请稍后重试") {}.padding(.horizontal, 28)
        SkeletonVideoGrid().frame(height: 560)
    }
    .frame(width: 1180, height: 680).background(GlassTheme.canvas)
    .environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-loading-states")
}

@MainActor
@Test func visualPreviewPlayerControls() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    model.duration = 754
    model.time = 291
    model.quality = "1080P 高清"
    let samples: [Double] = (0..<50).map { index in
        let wave: Double = 35 * sin(Double(index) / 4)
        return 40 + wave + Double(index % 7) * 6
    }
    model.highEnergy = HighEnergyCurve(stepSeconds: 15, samples: samples)
    let view = CustomPlayerView(model: model, danmaku: model.danmaku)
        .frame(width: 960, height: 540)
    try renderPreview(view, name: "bilinext-player-controls")
    var scrubbing = false
    var scrubTime = 291.0
    let scrubber = PlaybackScrubber(
        time: 291, duration: 754, buffered: 380, activity: samples, showsActivity: true,
        scrubbing: Binding(get: { scrubbing }, set: { scrubbing = $0 }),
        scrubTime: Binding(get: { scrubTime }, set: { scrubTime = $0 }), seek: { _ in }
    )
    .padding(20).frame(width: 760).background(.black)
    try renderPreview(scrubber, name: "bilinext-scrubber")
}

@MainActor
@Test func visualPreviewVideoActions() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = AppModel(sessionStore: SessionStore(directory: directory))
    let video = Video(bvid: "BV1111111111", title: "一", aid: 1)
    model.detail = VideoDetail(
        video: video, pages: [], description: "",
        stats: VideoStats(likes: 128_000, coins: 3456, favorites: 23_400, shares: 812))
    model.relation = VideoRelation(liked: true, coins: 1, favorited: false)
    let view = VideoActionBar(model: model, video: video)
        .padding(20).frame(width: 380).background(GlassTheme.canvas)
        .environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-video-actions")
}

@MainActor
@Test func visualPreviewComments() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    func parse(_ json: String) -> BiliNextCore.Comment {
        BiliNextCore.Comment.parse(
            (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])!
    }
    let reply = parse(
        #"{"rpid":2,"root":1,"parent":1,"like":3,"ctime":1760400000,"member":{"uname":"路过的鼠鼠"},"content":{"message":"回复 @小明 :03:21 这里真的笑死"}}"#
    )
    let root = parse(
        #"""
        {"rpid":1,"mid":7,"like":12843,"rcount":97,"ctime":1760390000,
         "member":{"uname":"小约翰可汗","level_info":{"current_level":6},"vip":{"vipStatus":1,"nickname_color":"#FB7299"}},
         "up_action":{"like":true},"reply_control":{"location":"IP属地：上海","max_line":6},
         "content":{"message":"本期参考资料都放在简介里了，03:21 那段是当年的原始录音。另一期 BV1xx411c7mD 也可以对照着看，欢迎讨论枯木逢春。"},
         "replies":[{"rpid":2,"root":1,"parent":1,"member":{"uname":"路过的鼠鼠"},
           "content":{"message":"回复 @小明 :03:21 这里真的笑死"}},
           {"rpid":3,"root":1,"parent":1,"member":{"uname":"阿B"},
           "content":{"message":"UP 主更新好快"}}]}
        """#)
    var rootWithReplies = root
    rootWithReplies.pinned = true
    let view = VStack(spacing: 0) {
        CommentRow(comment: rootWithReplies, uploaderID: 7) {}
        Divider()
        CommentRow(comment: reply, uploaderID: 7, compact: true, showsReplies: false)
    }
    .frame(width: 380).background(GlassTheme.canvas).environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-comments")
}

@MainActor
@Test func visualPreviewExpandedIntro() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    var detail = VideoDetail(
        video: Video(
            bvid: "BV1CUpy6oEiY", title: "【亚某爆料时间】王者十一周年限定盾山传说皮肤限时活动免费换", author: "王者荣耀",
            viewCount: "483000", danmakuCount: "1665", pubdate: Date()),
        pages: [],
        description: "限定皮肤活动 10 月 14 日开启，01:20 起是特效展示，往期爆料见 BV1xx411c7mD。\n欢迎在评论区讨论～",
        stats: VideoStats())
    detail.extras.tags = ["王者荣耀", "盾山", "皮肤爆料", "一塔千年", "游戏"]
    detail.extras.partition = "手机游戏"
    detail.extras.noReprint = true
    detail.extras.honors = ["热门收录"]
    let view = IntroDetails(detail: detail, expanded: true).padding(20)
        .frame(width: 380).background(GlassTheme.canvas).environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-intro-expanded")
}

@MainActor
@Test func visualPreviewCommentThread() throws {
    guard ProcessInfo.processInfo.environment["BILINEXT_RENDER_PREVIEW"] == "1" else { return }
    func reply(_ id: Int64, parent: Int64, _ author: String, _ text: String) -> BiliNextCore.Comment
    {
        BiliNextCore.Comment.parse(
            [
                "rpid": id, "root": 1, "parent": parent, "like": Int(id) * 3,
                "ctime": 1_760_400_000,
                "member": ["uname": author, "level_info": ["current_level": 5]],
                "content": ["message": text],
            ])!
    }
    let replies = [
        reply(2, parent: 1, "Cap_加西亚", "不问自取是为偷，何况他还知道人家牧民没走远。"),
        reply(3, parent: 2, "种猫猫", "回复 @Cap_加西亚 :等人家回来和人家说说，而且又不是没带钱"),
        reply(4, parent: 3, "Cap_加西亚", "回复 @种猫猫 :他这不是没说嘛"),
        reply(5, parent: 2, "静谧の扉守", "回复 @Cap_加西亚 :做的有点不地道。"),
        reply(6, parent: 1, "猫電", "因为以前是素材，这期是心肝。"),
        reply(7, parent: 6, "路人", "回复 @猫電 :哈哈"),
    ]
    let rows = CommentThread.rows(root: 1, replies: replies, collapsed: [6])
    let view = VStack(spacing: 0) {
        ForEach(rows) { row in
            ThreadReplyRow(row: row, uploaderID: 0, openDialog: nil, toggle: { _ in })
        }
    }
    .frame(width: 380).background(Color(white: 0.12)).environment(\.colorScheme, .dark)
    try renderPreview(view, name: "bilinext-comment-thread")
}
