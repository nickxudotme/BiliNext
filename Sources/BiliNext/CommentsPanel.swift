import AppKit
import BiliNextCore
import SwiftUI

/// Comments in Bilibili's two-level shape: root comments with a preview of their replies,
/// and a thread page pushed inside the panel for the full replies and conversations.
struct CommentsPanel: View {
    @ObservedObject var model: AppModel
    @State private var routes: [CommentRoute] = []
    @State private var viewer: PictureViewerState?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            CommentListPage(model: model, push: push)
            ForEach(Array(routes.enumerated()), id: \.element) { index, route in
                Group {
                    switch route {
                    case .thread(let root, let uploader):
                        CommentThreadPage(
                            model: model, root: root, uploaderID: uploader, push: push, pop: pop)
                    case .dialog(let root, let dialog, let uploader):
                        CommentDialogPage(
                            model: model, root: root, dialogID: dialog, uploaderID: uploader,
                            pop: pop)
                    }
                }
                .background(GlassTheme.canvas)
                .zIndex(Double(index + 1))
                .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .environment(\.openURL, OpenURLAction(handler: open))
        .environment(\.showCommentPictures) { pictures, index in
            viewer = PictureViewerState(pictures: pictures, index: index)
        }
        .sheet(item: $viewer) { state in PictureViewer(state: state) }
        .onChange(of: model.detail?.video.bvid) { _, _ in routes = [] }
    }

    private func push(_ route: CommentRoute) {
        withAnimation(Motion.emphasized(reduceMotion)) { routes.append(route) }
    }

    private func pop() {
        withAnimation(Motion.emphasized(reduceMotion)) { _ = routes.popLast() }
    }

    /// Links inside comments: timestamps seek the player, videos open as tabs (⌘ for the
    /// background), keywords search, and other pages go to the browser.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == CommentLinks.scheme {
            let value = url.pathComponents.dropFirst().first ?? ""
            switch url.host {
            case "seek":
                if let seconds = Double(value) {
                    model.seek(seconds)
                    model.toast = "跳到 " + timestamp(seconds)
                }
            case "video": openVideo(value)
            case "search": model.search(value)
            default: break
            }
            return .handled
        }
        if let bvid = Video.extractBVID(url.absoluteString),
            url.host?.hasSuffix("bilibili.com") == true
        {
            openVideo(bvid)
            return .handled
        }
        return .systemAction
    }

    private func openVideo(_ bvid: String) {
        let background = NSEvent.modifierFlags.contains(.command)
        Task {
            do {
                let detail = try await model.api.detail(bvid)
                model.open(detail.video, background: background)
            } catch { model.toast = error.localizedDescription }
        }
    }
}

enum CommentRoute: Hashable {
    case thread(Comment, uploaderID: Int64)
    case dialog(root: Comment, dialogID: Int64, uploaderID: Int64)

    static func == (lhs: CommentRoute, rhs: CommentRoute) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    private var key: String {
        switch self {
        case .thread(let root, _): "thread:\(root.id)"
        case .dialog(let root, let dialog, _): "dialog:\(root.id):\(dialog)"
        }
    }
}

/// Custom link targets inside comment text.
enum CommentLinks {
    static let scheme = "bilinext-comment"
    static func seek(_ seconds: Double) -> URL {
        URL(string: "\(scheme)://seek/\(Int(seconds))")!
    }
    static func video(_ bvid: String) -> URL { URL(string: "\(scheme)://video/\(bvid)")! }
    static func search(_ keyword: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "search"
        components.path = "/" + keyword
        return components.url ?? URL(string: "\(scheme)://search/")!
    }
}

// MARK: - Pages

private struct CommentListPage: View {
    @ObservedObject var model: AppModel
    let push: (CommentRoute) -> Void
    @State private var comments: [Comment] = []
    @State private var count = 0
    @State private var page = 0
    @State private var more = false
    @State private var sort = "hot"
    @State private var loading = false
    @State private var error: String?
    @State private var uploaderID: Int64 = 0
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("评论").font(GlassTheme.sectionTitleFont)
                if count > 0 {
                    Text(DisplayFormat.count(count)).font(GlassTheme.metadataFont)
                        .foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                SectionTabs(items: [("hot", "最热"), ("new", "最新")], selection: sort) {
                    sort = $0
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        CommentRow(comment: comment, uploaderID: uploaderID) {
                            push(.thread(comment, uploaderID: uploaderID))
                        }
                        .onAppear { if comment.id == comments.last?.id { load(more: true) } }
                        Divider().opacity(0.5).padding(.leading, 58)
                    }
                    CommentListFooter(
                        loading: loading, error: error, isEmpty: comments.isEmpty,
                        more: more, emptyTitle: "还没有评论",
                        retry: {
                            error = nil
                            load(more: !comments.isEmpty)
                        },
                        loadMore: { load(more: true) })
                }
                .padding(.bottom, 12)
            }
        }
        .task(id: "\(model.detail?.video.bvid ?? ""):\(sort)") { load() }
    }

    private func load(more append: Bool = false) {
        guard let aid = model.detail?.video.aid else { return }
        if append && (loading || !more || error != nil) { return }
        let token = UUID()
        generation = token
        if !append {
            comments = []
            page = 0
            count = 0
            more = false
        }
        loading = true
        error = nil
        let next = page + 1
        Task {
            do {
                let result = try await model.api.comments(
                    aid: aid, page: next, newest: sort == "new")
                guard token == generation else { return }
                var seen = Set(comments.map(\.id))
                comments += result.comments.filter { seen.insert($0.id).inserted }
                count = result.count
                more = result.hasMore
                page = next
                if result.uploaderID != 0 { uploaderID = result.uploaderID }
            } catch {
                guard token == generation else { return }
                self.error = error.localizedDescription
            }
            if token == generation { loading = false }
        }
    }
}

private struct CommentThreadPage: View {
    @ObservedObject var model: AppModel
    let root: Comment
    let uploaderID: Int64
    let push: (CommentRoute) -> Void
    let pop: () -> Void
    @State private var replies: [Comment] = []
    @State private var page = 0
    @State private var count = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentPageHeader(title: "评论详情", back: pop)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    CommentRow(comment: root, uploaderID: uploaderID, showsReplies: false)
                    Rectangle().fill(.primary.opacity(0.05)).frame(height: 8)
                    Text(count > 0 ? "相关回复共 \(count) 条" : "相关回复")
                        .font(GlassTheme.metadataFont.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    ForEach(replies) { reply in
                        CommentRow(
                            comment: reply, uploaderID: uploaderID, compact: true,
                            showsReplies: false,
                            openDialog: reply.dialogID != 0 && reply.dialogID != reply.id
                                ? {
                                    push(
                                        .dialog(
                                            root: root, dialogID: reply.dialogID,
                                            uploaderID: uploaderID))
                                }
                                : nil
                        )
                        .onAppear { if reply.id == replies.last?.id { load() } }
                    }
                    CommentListFooter(
                        loading: loading, error: error, isEmpty: replies.isEmpty, more: more,
                        emptyTitle: "暂无回复", retry: load, loadMore: load)
                }
                .padding(.bottom, 12)
            }
        }
        .task { load() }
    }

    private func load() {
        guard !loading, more, let aid = model.detail?.video.aid else { return }
        loading = true
        error = nil
        let next = page + 1
        Task {
            do {
                let result = try await model.api.comments(aid: aid, page: next, root: root.id)
                var seen = Set(replies.map(\.id))
                replies += result.comments.filter { seen.insert($0.id).inserted }
                count = result.count
                more = result.hasMore
                page = next
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}

private struct CommentDialogPage: View {
    @ObservedObject var model: AppModel
    let root: Comment
    let dialogID: Int64
    let uploaderID: Int64
    let pop: () -> Void
    @State private var replies: [Comment] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentPageHeader(title: "查看对话", back: pop)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(replies) { reply in
                        CommentRow(
                            comment: reply, uploaderID: uploaderID, compact: true,
                            showsReplies: false)
                    }
                    CommentListFooter(
                        loading: loading, error: error, isEmpty: replies.isEmpty, more: false,
                        emptyTitle: "对话已不可见", retry: { Task { await load() } }, loadMore: {})
                }
                .padding(.bottom, 12)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let aid = model.detail?.video.aid else { return }
        loading = true
        error = nil
        do {
            replies = try await model.api.dialog(aid: aid, root: root.id, dialog: dialogID)
        } catch { self.error = error.localizedDescription }
        loading = false
    }
}

private struct CommentPageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: back) {
                Image(systemName: "chevron.left").font(GlassTheme.iconFont.weight(.semibold))
                    .iconControlFrame()
            }
            .buttonStyle(InteractionButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("返回").accessibilityLabel("返回")
            Text(title).font(GlassTheme.sectionTitleFont)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
}

private struct CommentListFooter: View {
    let loading: Bool
    let error: String?
    let isEmpty: Bool
    let more: Bool
    let emptyTitle: String
    let retry: () -> Void
    let loadMore: () -> Void

    var body: some View {
        Group {
            if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(16)
            } else if let error {
                ErrorBanner(message: error, retry: retry).padding(16)
            } else if isEmpty {
                ContentUnavailableView(
                    emptyTitle, systemImage: "bubble.left.and.bubble.right",
                    description: Text("来抢第一个沙发吧。")
                )
                .padding(.top, 40)
            } else if more {
                Button("加载更多", action: loadMore).buttonStyle(InteractionButtonStyle(kind: .row))
                    .font(GlassTheme.labelFont).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(12)
            }
        }
    }
}

// MARK: - Rows

/// One comment: avatar column, then identity, text, pictures, meta line and reply preview.
struct CommentRow: View {
    let comment: Comment
    let uploaderID: Int64
    var compact = false
    var showsReplies = true
    var openThread: (() -> Void)? = nil
    var openDialog: (() -> Void)? = nil
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        comment: Comment, uploaderID: Int64, compact: Bool = false, showsReplies: Bool = true,
        openDialog: (() -> Void)? = nil, openThread: (() -> Void)? = nil
    ) {
        self.comment = comment
        self.uploaderID = uploaderID
        self.compact = compact
        self.showsReplies = showsReplies
        self.openThread = openThread
        self.openDialog = openDialog
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(url: comment.avatar)
                .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
            VStack(alignment: .leading, spacing: 6) {
                CommentIdentity(comment: comment, uploaderID: uploaderID)
                CollapsibleCommentText(comment: comment)
                if !comment.pictures.isEmpty { CommentPictures(pictures: comment.pictures) }
                footer
                if showsReplies, comment.replyCount > 0 || !comment.replies.isEmpty {
                    replyPreview
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(
                [DisplayFormat.relativeDate(comment.date), comment.location].compactMap { $0 }
                    .joined(separator: " · ")
            )
            .foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            Label(
                comment.likes > 0 ? DisplayFormat.count(comment.likes) : "赞",
                systemImage: "hand.thumbsup"
            )
            .labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
            if comment.likedByUploader {
                Text("UP 觉得很赞").lineLimit(1).fixedSize().font(
                    GlassTheme.captionFont.weight(.medium)
                )
                .foregroundStyle(GlassTheme.accent)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(GlassTheme.accent.opacity(0.12), in: Capsule())
            }
            if let openDialog {
                Button("查看对话", action: openDialog).buttonStyle(.plain)
                    .foregroundStyle(GlassTheme.accent)
            }
            Spacer(minLength: 0)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis").font(GlassTheme.labelFont.weight(.semibold))
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .opacity(hovered ? 1 : 0)
            .animation(Motion.quick(reduceMotion), value: hovered)
            .accessibilityLabel("评论选项")
        }
        .font(GlassTheme.captionFont).foregroundStyle(.secondary)
    }

    @ViewBuilder private var menuItems: some View {
        Button("复制评论") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(comment.text, forType: .string)
        }
        if let openThread { Button("查看全部回复", action: openThread) }
    }

    /// Up to three replies in a soft block, then the entry to the full thread.
    private var replyPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(comment.replies.prefix(3)) { reply in
                CommentText(comment: reply, prefix: reply.author)
                    .font(GlassTheme.labelFont).lineSpacing(3).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let openThread {
                Button(action: openThread) {
                    HStack(spacing: 2) {
                        Text(comment.replyCount > 0 ? "共 \(comment.replyCount) 条回复" : "查看回复")
                        Image(systemName: "chevron.right").font(GlassTheme.smallIconFont)
                    }
                    .font(GlassTheme.metadataFont.weight(.medium))
                    .foregroundStyle(GlassTheme.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .primary.opacity(0.045), in: RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
    }
}

private struct CommentIdentity: View {
    let comment: Comment
    let uploaderID: Int64

    var body: some View {
        HStack(spacing: 5) {
            Text(comment.author).font(GlassTheme.metadataFont.weight(.medium)).lineLimit(1)
                .foregroundStyle(comment.nameColor.flatMap(Color.init(hex:)) ?? .secondary)
            if comment.level > 0 {
                Text("LV\(comment.level)").font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(levelColor, lineWidth: 1)
                    }
            }
            if uploaderID != 0 && comment.authorID == uploaderID {
                badge("UP", filled: true)
            }
            if comment.pinned { badge("置顶", filled: false) }
        }
    }

    /// Bilibili's level colours: grey to green to blue to orange to red.
    private var levelColor: Color {
        switch comment.level {
        case ...1: .gray
        case 2: .green
        case 3: .blue
        case 4: .yellow
        case 5: .orange
        default: .red
        }
    }

    private func badge(_ title: String, filled: Bool) -> some View {
        Text(title).font(.system(size: 10, weight: .bold))
            .foregroundStyle(filled ? .white : GlassTheme.accent)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background {
                RoundedRectangle(cornerRadius: 3)
                    .fill(filled ? GlassTheme.accent : GlassTheme.accent.opacity(0.12))
            }
    }
}

/// Long comments start at Bilibili's line limit; 展开 appears only when the text needs more
/// lines than that at the current width.
private struct CollapsibleCommentText: View {
    let comment: Comment
    @State private var expanded = false
    @State private var width: CGFloat = 0

    private static let font = NSFont.systemFont(ofSize: 15)
    private static let lineSpacing: CGFloat = 4

    private var truncates: Bool {
        guard comment.maxLines > 0, width > 0 else { return false }
        // Emotes render about two characters wide.
        let text = comment.emotes.keys.reduce(comment.text) {
            $0.replacingOccurrences(of: $1, with: "表情")
        }
        let height = (text as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Self.font]
        ).height
        let line = Self.font.ascender - Self.font.descender + Self.font.leading
        return Int((height / line).rounded()) > comment.maxLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CommentText(comment: comment)
                .font(GlassTheme.bodyFont).lineSpacing(Self.lineSpacing)
                .lineLimit(expanded || comment.maxLines <= 0 ? nil : comment.maxLines)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
            if truncates {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.plain)
                    .font(GlassTheme.metadataFont.weight(.medium)).foregroundStyle(
                        GlassTheme.accent)
            }
        }
    }
}

/// Comment text with inline emotes and tappable links, mentions, BV IDs and timestamps.
struct CommentText: View {
    let segments: [CommentSegment]
    var prefix: String? = nil
    @ObservedObject private var emotes = EmoteCache.shared

    init(comment: Comment, prefix: String? = nil) {
        self.init(segments: CommentSegment.split(comment), prefix: prefix)
    }

    init(segments: [CommentSegment], prefix: String? = nil) {
        self.segments = segments
        self.prefix = prefix
    }

    var body: some View {
        var text = Text("")
        if let prefix {
            text = Text(
                "\(text)\(Text(prefix + "：").fontWeight(.semibold).foregroundStyle(.secondary))")
        }
        for segment in segments {
            text = Text("\(text)\(piece(segment))")
        }
        return text
    }

    private func piece(_ segment: CommentSegment) -> Text {
        switch segment {
        case .text(let value): return Text(value)
        case .emote(let key, let url):
            if let image = emotes.image(for: url) {
                return Text(Image(nsImage: image)).baselineOffset(-4)
            }
            return Text(key)
        case .link(let key, let target):
            let url: URL =
                switch target {
                case .search(let keyword): CommentLinks.search(keyword)
                case .page(let page): page
                }
            return link(key, url, symbol: "magnifyingglass")
        case .mention(let name): return Text("@" + name).foregroundStyle(GlassTheme.accent)
        case .video(let bvid): return link(bvid, CommentLinks.video(bvid), symbol: "play.rectangle")
        case .time(let label, let seconds):
            return link(label, CommentLinks.seek(seconds), symbol: nil)
        }
    }

    private func link(_ label: String, _ url: URL, symbol: String?) -> Text {
        var attributed = AttributedString(label)
        attributed.link = url
        attributed.foregroundColor = GlassTheme.accent
        if let symbol {
            return Text("\(Image(systemName: symbol))\(attributed)").foregroundStyle(
                GlassTheme.accent)
        }
        return Text(attributed)
    }
}

/// Emote images, decoded once at text size and shared by every comment.
@MainActor
final class EmoteCache: ObservableObject {
    static let shared = EmoteCache()
    private var images: [URL: NSImage] = [:]
    private var loading = Set<URL>()

    func image(for url: URL) -> NSImage? {
        if let image = images[url] { return image }
        guard !loading.contains(url) else { return nil }
        loading.insert(url)
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                let image = NSImage(data: data)
            else { return }
            image.size = NSSize(width: 20, height: 20)
            images[url] = image
            objectWillChange.send()
        }
        return nil
    }
}

// MARK: - Pictures

private struct CommentPictures: View {
    let pictures: [CommentPicture]
    @Environment(\.showCommentPictures) private var show

    var body: some View {
        if pictures.count == 1, let picture = pictures.first {
            let ratio =
                picture.width > 0 && picture.height > 0 ? picture.width / picture.height : 4 / 3
            thumbnail(picture, index: 0)
                .frame(
                    width: ratio >= 1 ? 200 : 200 * ratio, height: ratio >= 1 ? 200 / ratio : 200)
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(78), spacing: 6), count: 3),
                alignment: .leading, spacing: 6
            ) {
                ForEach(Array(pictures.prefix(9).enumerated()), id: \.offset) { index, picture in
                    thumbnail(picture, index: index).frame(width: 78, height: 78)
                }
            }
        }
    }

    private func thumbnail(_ picture: CommentPicture, index: Int) -> some View {
        Button {
            show(pictures, index)
        } label: {
            ThumbnailView(url: picture.url, pixels: 480) {
                Rectangle().fill(.primary.opacity(0.06))
            }
            .clipShape(RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(InteractionButtonStyle(kind: .card))
        .accessibilityLabel("查看图片 \(index + 1)")
    }
}

struct PictureViewerState: Identifiable {
    let id = UUID()
    let pictures: [CommentPicture]
    var index: Int
}

private struct PictureViewer: View {
    @State var state: PictureViewerState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black
            ThumbnailView(url: state.pictures[state.index].url, pixels: 2400) {
                ProgressView().tint(.white)
            }
            .scaledToFit()
            .id(state.index)
            HStack {
                arrow("chevron.left", disabled: state.index == 0) { state.index -= 1 }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                arrow("chevron.right", disabled: state.index >= state.pictures.count - 1) {
                    state.index += 1
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .padding(16)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(GlassTheme.iconFont.weight(.semibold))
                    .iconControlFrame(size: 34)
            }
            .buttonStyle(InteractionButtonStyle()).chromeSurface(in: Circle(), interactive: true)
            .keyboardShortcut(.cancelAction).padding(14)
        }
        .overlay(alignment: .bottom) {
            if state.pictures.count > 1 {
                Text("\(state.index + 1) / \(state.pictures.count)").font(GlassTheme.labelFont)
                    .monospacedDigit().padding(.horizontal, 12).padding(.vertical, 6)
                    .chromeSurface(in: Capsule()).padding(16)
            }
        }
        .environment(\.colorScheme, .dark)
        .foregroundStyle(.white)
        .frame(minWidth: 760, minHeight: 560)
    }

    private func arrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            Image(systemName: symbol).font(GlassTheme.largeIconFont.weight(.semibold))
                .iconControlFrame(size: 44)
        }
        .buttonStyle(InteractionButtonStyle()).chromeSurface(in: Circle(), interactive: true)
        .disabled(disabled).opacity(disabled ? 0 : 1)
    }
}

private struct ShowCommentPicturesKey: EnvironmentKey {
    static let defaultValue: @MainActor ([CommentPicture], Int) -> Void = { _, _ in }
}

extension EnvironmentValues {
    var showCommentPictures: @MainActor ([CommentPicture], Int) -> Void {
        get { self[ShowCommentPicturesKey.self] }
        set { self[ShowCommentPicturesKey.self] = newValue }
    }
}

extension Color {
    /// `#RRGGBB` from Bilibili's colour fields.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
