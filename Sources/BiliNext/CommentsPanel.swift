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
            // Pages sit directly on the panel's glass, so only the top one is shown.
            CommentListPage(model: model, push: push)
                .opacity(routes.isEmpty ? 1 : 0).allowsHitTesting(routes.isEmpty)
            ForEach(Array(routes.enumerated()), id: \.element) { index, route in
                Group {
                    switch route {
                    case .thread(let root, let uploader, let focus):
                        CommentThreadPage(
                            model: model, root: root, uploaderID: uploader, focus: focus,
                            push: push, pop: pop)
                    case .dialog(let root, let dialog, let uploader):
                        CommentDialogPage(
                            model: model, root: root, dialogID: dialog, uploaderID: uploader,
                            pop: pop)
                    }
                }
                .opacity(index == routes.count - 1 ? 1 : 0)
                .allowsHitTesting(index == routes.count - 1)
                .zIndex(Double(index + 1))
                .transition(.move(edge: .trailing))
            }
        }
        .clipped()
        .environment(\.openURL, OpenURLAction(handler: open))
        .environment(\.videoDuration, model.duration)
        .environment(\.openMemberSpace) { comment in
            model.openSpace(
                mid: comment.authorID, name: comment.author, avatar: comment.avatar,
                background: NSEvent.modifierFlags.contains(.command))
        }
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
    /// `focus` is a reply to scroll to and highlight, as when tapped in the preview.
    case thread(Comment, uploaderID: Int64, focus: Comment? = nil)
    case dialog(root: Comment, dialogID: Int64, uploaderID: Int64)

    static func == (lhs: CommentRoute, rhs: CommentRoute) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
    private var key: String {
        switch self {
        case .thread(let root, _, let focus): "thread:\(root.id):\(focus?.id ?? 0)"
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
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        CommentRow(
                            comment: comment, uploaderID: uploaderID,
                            openReply: { reply in
                                push(.thread(comment, uploaderID: uploaderID, focus: reply))
                            }
                        ) {
                            push(.thread(comment, uploaderID: uploaderID))
                        }
                        Divider().opacity(0.5).padding(.leading, 58)
                    }
                    PageSentinel { load(more: true) }
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
    var focus: Comment? = nil
    let push: (CommentRoute) -> Void
    let pop: () -> Void
    @State private var replies: [Comment] = []
    /// The reply to scroll to once it is loaded; cleared after scrolling.
    @State private var pendingFocus: Int64?
    @State private var highlighted: Int64?
    @State private var page = 0
    @State private var count = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    @State private var collapsed = Set<Int64>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var rows: [CommentThreadRow] {
        CommentThread.rows(root: root.id, replies: replies, collapsed: collapsed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CommentPageHeader(title: "评论详情", back: pop)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        CommentRow(comment: root, uploaderID: uploaderID, showsReplies: false)
                        Rectangle().fill(.primary.opacity(0.05)).frame(height: 8)
                        Text(count > 0 ? "相关回复共 \(count) 条" : "相关回复")
                            .font(GlassTheme.metadataFont.weight(.semibold)).foregroundStyle(
                                .secondary
                            )
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                        // Replies nest under the reply they answer, Reddit style; a guide line per
                        // level shows who answered whom, and clicking a line folds that branch.
                        ForEach(rows) { row in
                            ThreadReplyRow(
                                row: row, uploaderID: uploaderID,
                                highlighted: highlighted == row.id,
                                // The tree shows the conversation; the dialog page remains for
                                // replies whose parent is not loaded.
                                openDialog: row.depth == 1 && row.comment.parentID != root.id
                                    && row.comment.dialogID != 0
                                    ? {
                                        push(
                                            .dialog(
                                                root: root, dialogID: row.comment.dialogID,
                                                uploaderID: uploaderID))
                                    }
                                    : nil,
                                toggle: { id in
                                    withAnimation(Motion.standard(reduceMotion)) {
                                        if collapsed.contains(id) {
                                            collapsed.remove(id)
                                        } else {
                                            collapsed.insert(id)
                                        }
                                    }
                                }
                            )
                        }
                        PageSentinel(load: load)
                        CommentListFooter(
                            loading: loading, error: error, isEmpty: replies.isEmpty, more: more,
                            emptyTitle: "暂无回复", retry: load, loadMore: load)
                    }
                    .padding(.bottom, 12)
                }
                .onChange(of: rows.map(\.id)) { _, ids in reveal(in: ids, proxy: proxy) }
            }
        }
        .task {
            pendingFocus = focus?.id
            load()
        }
    }

    /// Scrolls to the focused reply when it appears, then highlights it briefly.
    private func reveal(in ids: [Int64], proxy: ScrollViewProxy) {
        guard let id = pendingFocus, ids.contains(id) else { return }
        pendingFocus = nil
        Task {
            // Let the new rows lay out before scrolling to one of them.
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(Motion.emphasized(reduceMotion)) {
                proxy.scrollTo(id, anchor: .center)
            }
            highlighted = id
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation(.easeOut(duration: 0.6)) { if highlighted == id { highlighted = nil } }
        }
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
            // Keep paging towards a focused reply; past 10 pages, or at the end, show the
            // previewed copy on its own so the tap still lands somewhere.
            if let id = pendingFocus, !replies.contains(where: { $0.id == id }) {
                if more && page < 10 && error == nil {
                    load()
                } else if let focus {
                    replies.insert(focus, at: 0)
                }
            }
        }
    }
}

/// One reply in the 评论详情 tree. A line leaves each reply's avatar and runs down past its
/// replies, bending into each of their avatars, so who answered whom reads at a glance; it
/// stops after the last reply. The knob under an avatar, or the line itself, folds the branch.
struct ThreadReplyRow: View {
    let row: CommentThreadRow
    let uploaderID: Int64
    var highlighted = false
    let openDialog: (() -> Void)?
    let toggle: (Int64) -> Void

    static let indent: CGFloat = 24
    /// `CommentRow`'s leading and top padding and compact avatar.
    static let inset: CGFloat = 16
    static let top: CGFloat = 12
    static let avatar: CGFloat = 28

    private var offset: CGFloat { CGFloat(row.depth - 1) * Self.indent }
    /// The centre x of the avatar at `level` (0 is a reply to the root comment).
    private static func centre(_ level: Int) -> CGFloat {
        inset + CGFloat(level) * indent + avatar / 2
    }

    var body: some View {
        Group {
            if row.collapsed {
                folded
            } else {
                CommentRow(
                    comment: row.comment, uploaderID: uploaderID, compact: true,
                    showsReplies: false, openDialog: openDialog)
            }
        }
        .padding(.leading, offset)
        .background {
            // The reply opened from the preview glows briefly.
            RoundedRectangle(cornerRadius: GlassTheme.rowRadius)
                .fill(GlassTheme.accent.opacity(highlighted ? 0.14 : 0))
                .padding(.leading, offset + 6).padding(.trailing, 6).padding(.vertical, 2)
        }
        .background(alignment: .topLeading) { lines }
        .id(row.id)
        .overlay(alignment: .topLeading) {
            if row.descendants > 0 && !row.collapsed {
                FoldKnob(expanded: true) { toggle(row.id) }
                    .offset(
                        x: Self.centre(row.depth - 1) - FoldKnob.size / 2,
                        y: Self.top + Self.avatar + 6
                    )
                    .help("收起 \(row.descendants) 条回复")
            }
        }
    }

    /// Ancestors' lines passing through, the bend into this avatar, and this reply's own line.
    private var lines: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(Array(row.ancestors.enumerated()), id: \.element) { level, ancestor in
                    let nearest = level == row.ancestors.count - 1
                    let continues = row.rails.indices.contains(level) && row.rails[level]
                    if nearest || continues {
                        BranchLine(
                            x: Self.centre(level),
                            bend: nearest ? Self.centre(level + 1) - Self.avatar / 2 - 3 : nil,
                            from: 0, continues: continues, height: proxy.size.height
                        ) { toggle(ancestor) }
                    }
                }
                if row.descendants > 0 && !row.collapsed {
                    BranchLine(
                        x: Self.centre(row.depth - 1), bend: nil,
                        from: Self.top + Self.avatar + 4, continues: true,
                        height: proxy.size.height
                    ) { toggle(row.id) }
                }
            }
        }
    }

    private var folded: some View {
        Button {
            toggle(row.id)
        } label: {
            HStack(spacing: 10) {
                AvatarView(url: row.comment.avatar).frame(width: Self.avatar, height: Self.avatar)
                    .opacity(0.7)
                    .overlay(alignment: .bottomTrailing) {
                        FoldKnob(expanded: false) {}.allowsHitTesting(false).offset(x: 4, y: 4)
                    }
                Text(row.comment.author).font(GlassTheme.metadataFont.weight(.medium))
                    .foregroundStyle(.secondary).lineLimit(1)
                Text("已收起 \(row.descendants) 条回复").font(GlassTheme.captionFont)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.leading, Self.inset).padding(.trailing, 16)
            .padding(.top, Self.top).padding(.bottom, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("展开 \(row.comment.author) 下的 \(row.descendants) 条回复")
    }
}

/// A small −/+ disc on a branch line.
private struct FoldKnob: View {
    static let size: CGFloat = 16
    let expanded: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "minus" : "plus")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill(Color(white: hovered ? 0.24 : 0.17)))
                .overlay { Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(expanded ? "收起回复" : "展开回复")
    }
}

/// A branch line at `x` from `from` downwards: with `bend`, it curves right into an avatar at
/// the avatar's centre height and carries on only if `continues`. Hover brightens it; a click
/// folds the branch it belongs to.
private struct BranchLine: View {
    let x: CGFloat
    let bend: CGFloat?
    let from: CGFloat
    let continues: Bool
    let height: CGFloat
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let radius: CGFloat = 8
    private static let bendY = ThreadReplyRow.top + ThreadReplyRow.avatar / 2

    var body: some View {
        let path = Path { path in
            if let bend {
                let y = Self.bendY
                path.move(to: CGPoint(x: x, y: from))
                path.addLine(to: CGPoint(x: x, y: y - Self.radius))
                path.addQuadCurve(
                    to: CGPoint(x: x + Self.radius, y: y), control: CGPoint(x: x, y: y))
                path.addLine(to: CGPoint(x: max(x + Self.radius, bend), y: y))
                if continues {
                    path.move(to: CGPoint(x: x, y: y - Self.radius))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
            } else {
                path.move(to: CGPoint(x: x, y: from))
                path.addLine(to: CGPoint(x: x, y: height))
            }
        }
        path.stroke(
            .primary.opacity(hovered ? 0.4 : 0.17),
            style: StrokeStyle(lineWidth: hovered ? 2 : 1.5, lineCap: .round, lineJoin: .round)
        )
        .contentShape(
            Path(CGRect(x: x - 6, y: from, width: 12, height: max(0, height - from)))
        )
        .onTapGesture(perform: action)
        .onHover { hovered = $0 }
        .animation(Motion.quick(reduceMotion), value: hovered)
        .accessibilityHidden(true)
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
                VStack(alignment: .leading, spacing: 0) {
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

/// Loads the next page when the end of a comment list scrolls into view.
///
/// The lists are plain `VStack`s: in a `LazyVStack`, rows that change height (展开, folding a
/// branch, a page arriving) make SwiftUI keep re-adjusting the scroll offset and re-placing
/// rows forever, freezing the window (2026-10-15). A plain stack also creates every row at
/// once, so paging cannot hang off each row's `onAppear`.
private struct PageSentinel: View {
    let load: () -> Void

    var body: some View {
        Color.clear.frame(height: 1)
            .onScrollVisibilityChange(threshold: 0.01) { visible in if visible { load() } }
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
    /// Opens the thread at one of the previewed replies.
    var openReply: ((Comment) -> Void)? = nil
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.openMemberSpace) private var openMemberSpace
    init(
        comment: Comment, uploaderID: Int64, compact: Bool = false, showsReplies: Bool = true,
        openDialog: (() -> Void)? = nil, openReply: ((Comment) -> Void)? = nil,
        openThread: (() -> Void)? = nil
    ) {
        self.comment = comment
        self.uploaderID = uploaderID
        self.compact = compact
        self.showsReplies = showsReplies
        self.openThread = openThread
        self.openDialog = openDialog
        self.openReply = openReply
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                openMemberSpace(comment)
            } label: {
                AvatarView(url: comment.avatar)
                    .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
            }
            .buttonStyle(.plain).disabled(comment.authorID == 0)
            .help("打开 \(comment.author) 的主页")
            VStack(alignment: .leading, spacing: 6) {
                CommentIdentity(comment: comment, uploaderID: uploaderID)
                CollapsibleCommentText(comment: comment)
                if !comment.pictures.isEmpty { CommentPictures(pictures: comment.pictures) }
                footer
                if showsReplies, !comment.replies.isEmpty || comment.replyCount > 0 {
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
                Label("UP 觉得很赞", systemImage: "heart.fill").labelStyle(.titleAndIcon)
                    .lineLimit(1).fixedSize().font(GlassTheme.captionFont.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let openDialog {
                Button("查看对话", action: openDialog).buttonStyle(.plain)
                    .foregroundStyle(GlassTheme.accent)
            }
            Spacer(minLength: 0)
            // Each Menu is an AppKit pop-up rebuilt on every update, so only the hovered row
            // has one. It floats over a fixed placeholder so hovering never changes the
            // footer's height.
            Color.clear.frame(width: 24, height: 20)
                .overlay {
                    if hovered {
                        Menu {
                            menuItems
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(GlassTheme.labelFont.weight(.semibold))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .transition(.opacity)
                        .accessibilityLabel("评论选项")
                    }
                }
                .animation(Motion.quick(reduceMotion), value: hovered)
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
                PreviewReplyLine(reply: reply) { openReply?(reply) }
                    .disabled(openReply == nil)
            }
            // Only offer the thread when the preview leaves replies out, as the official app.
            if let openThread, comment.replyCount > min(3, comment.replies.count) {
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
            .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: GlassTheme.rowRadius))
    }
}

/// A reply in a comment's preview block; clicking opens the thread at it.
private struct PreviewReplyLine: View {
    let reply: Comment
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            CommentText(comment: reply, prefix: reply.author)
                .font(GlassTheme.labelFont).lineSpacing(3).lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    .primary.opacity(hovered ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6)
                )
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("在评论详情中查看")
    }
}

private struct CommentIdentity: View {
    let comment: Comment
    let uploaderID: Int64
    @Environment(\.openMemberSpace) private var openMemberSpace

    var body: some View {
        HStack(spacing: 5) {
            Button {
                openMemberSpace(comment)
            } label: {
                Text(comment.author).font(GlassTheme.metadataFont.weight(.medium)).lineLimit(1)
                    .foregroundStyle(comment.nameColor.flatMap(Color.init(hex:)) ?? .secondary)
            }
            .buttonStyle(.plain).disabled(comment.authorID == 0)
            if comment.level > 0 {
                Text("LV\(comment.level)").font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(levelColor, lineWidth: 1)
                    }
            }
            if uploaderID != 0 && comment.authorID == uploaderID { badge("UP") }
            if comment.pinned { badge("置顶") }
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

    /// Neutral tags: identity is information, not the viewer's own state.
    private func badge(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Long comments start at Bilibili's line limit; 展开 appears only when the text needs more
/// lines than that at the current width.
private struct CollapsibleCommentText: View {
    let comment: Comment
    @State private var expanded = false
    @AppStorage(Preferences.expandComments) private var alwaysExpand = false
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

    private var cut: Bool { !expanded && !alwaysExpand && comment.maxLines > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CommentText(comment: comment)
                .font(GlassTheme.bodyFont).lineSpacing(Self.lineSpacing)
                .lineLimit(cut ? comment.maxLines : nil)
                // Selectable text that is cut off shows its full text when clicked without
                // growing the row, so a click on a cut comment expands it instead, and
                // selection works once it is shown in full. Links inside still open.
                .modifier(SelectableText(enabled: !cut))
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { if cut && truncates { expanded = true } },
                    isEnabled: cut && truncates
                )
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    width = $0
                }
            if truncates && !alwaysExpand {
                Button(expanded ? "收起" : "展开") { expanded.toggle() }.buttonStyle(.plain)
                    .font(GlassTheme.metadataFont.weight(.medium)).foregroundStyle(
                        GlassTheme.accent)
            }
        }
    }
}

/// Text selection that can be switched off: cut-off selectable text spills its full text out
/// when clicked without growing its frame, so callers enable it only when shown in full.
struct SelectableText: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled { content.textSelection(.enabled) } else { content.textSelection(.disabled) }
    }
}

/// Comment text with inline emotes and tappable links, mentions, BV IDs and timestamps.
struct CommentText: View {
    let segments: [CommentSegment]
    var prefix: String? = nil
    @ObservedObject private var emotes = EmoteCache.shared
    @Environment(\.videoDuration) private var videoDuration

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
            // Clock times such as 23:59 are not positions in a shorter video.
            guard videoDuration <= 0 || seconds <= videoDuration else { return Text(label) }
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
            // Very tall pictures, such as long screenshots, crop to a readable width.
            thumbnail(
                picture, index: 0,
                size: CGSize(
                    width: ratio >= 1 ? 200 : max(120, 200 * ratio),
                    height: ratio >= 1 ? 200 / ratio : 200))
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(78), spacing: 6), count: 3),
                alignment: .leading, spacing: 6
            ) {
                ForEach(Array(pictures.prefix(9).enumerated()), id: \.offset) { index, picture in
                    thumbnail(picture, index: index, size: CGSize(width: 78, height: 78))
                }
            }
        }
    }

    private func thumbnail(_ picture: CommentPicture, index: Int, size: CGSize) -> some View {
        Button {
            show(pictures, index)
        } label: {
            ThumbnailView(url: picture.url, pixels: 480) {
                Rectangle().fill(.primary.opacity(0.06))
            }
            .frame(width: size.width, height: size.height)
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

private struct VideoDurationKey: EnvironmentKey {
    static let defaultValue: Double = 0
}

private struct OpenMemberSpaceKey: EnvironmentKey {
    static let defaultValue: @MainActor (Comment) -> Void = { _ in }
}

private struct ShowCommentPicturesKey: EnvironmentKey {
    static let defaultValue: @MainActor ([CommentPicture], Int) -> Void = { _, _ in }
}

extension EnvironmentValues {
    /// The open video's length, so only timestamps inside it become seek links.
    var videoDuration: Double {
        get { self[VideoDurationKey.self] }
        set { self[VideoDurationKey.self] = newValue }
    }

    /// Opens a commenter's space page as a tab.
    var openMemberSpace: @MainActor (Comment) -> Void {
        get { self[OpenMemberSpaceKey.self] }
        set { self[OpenMemberSpaceKey.self] = newValue }
    }

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
