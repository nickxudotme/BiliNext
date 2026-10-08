import SwiftUI
import BiliNextCore

struct VideoCommunityView: View {
    @ObservedObject var model: AppModel
    let section: String
    @State private var comments: [Comment] = []
    @State private var related: [Video] = []
    @State private var count = 0
    @State private var page = 0
    @State private var more = false
    @State private var newest = false
    @State private var loading = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(section == "评论" ? "评论" : "接着看").font(.headline)
                Spacer()
                if section == "评论" { Picker("排序", selection: $newest) { Text("最热").tag(false); Text("最新").tag(true) }.labelsHidden().frame(width: 80) }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if section == "简介" { Text(model.detail?.description ?? "").textSelection(.enabled).foregroundStyle(.secondary) }
                    else if section == "相关推荐" {
                        ForEach(related) { video in
                            Button { model.open(video, background: NSEvent.modifierFlags.contains(.command)) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    AsyncImage(url: video.cover) { $0.resizable().scaledToFill() } placeholder: { Color.gray.opacity(0.15) }.frame(width: 120, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 8) { Text(video.title).lineLimit(2); Text(video.author).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    } else {
                        if count > 0 { Text("\(count) 条评论").font(.caption).foregroundStyle(.secondary) }
                        ForEach(comments) { comment in CommentThreadView(comment: comment, aid: model.detail?.video.aid ?? 0, api: model.api) }
                        if more { Button("加载更多评论") { load(more: true) }.disabled(loading) }
                    }
                    if section != "简介" {
                        if loading { ProgressView().frame(maxWidth: .infinity) }
                        else if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { load() } }
                        else if section == "评论" && comments.isEmpty { Text("暂无评论").foregroundStyle(.secondary) }
                        else if section == "相关推荐" && related.isEmpty { Text("暂无相关推荐").foregroundStyle(.secondary) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
        }
        .padding(16)
        .onAppear { load() }
        .onChange(of: model.detail?.video.bvid) { _, _ in load() }
        .onChange(of: section) { _, _ in load() }
        .onChange(of: newest) { _, _ in load() }
        .onDisappear { task?.cancel() }
    }
    private func load(more append: Bool = false) {
        task?.cancel(); generation = UUID(); let token = generation
        guard let video = model.detail?.video else { return }
        if !append { comments = []; related = []; count = 0; page = 0; more = false }
        error = nil; loading = section != "简介"
        let target = section; let nextPage = page + 1; let order = newest
        task = Task { @MainActor in
            do {
                if target == "评论", let aid = video.aid {
                    let result = try await model.api.comments(aid: aid, page: nextPage, newest: order)
                    guard !Task.isCancelled, token == generation else { return }
                    var seen = Set<Int64>(); comments = (comments + result.comments).filter { seen.insert($0.id).inserted }; count = result.count; more = result.hasMore; page = nextPage
                } else if target == "相关推荐" {
                    let result = try await model.api.related(bvid: video.bvid)
                    guard !Task.isCancelled, token == generation else { return }; related = result
                }
            } catch { guard !Task.isCancelled, token == generation else { return }; self.error = error.localizedDescription }
            if token == generation { loading = false }
        }
    }
}

private struct CommentThreadView: View {
    let comment: Comment
    let aid: Int64
    let api: BilibiliAPI
    @State private var collapsed = false
    @State private var replies: [Comment] = []
    @State private var loadedPage = 0
    @State private var request = 0
    @State private var more = true
    @State private var loading = false
    @State private var error: String?
    private var branches: [CommentBranch] {
        var seen = Set<Int64>()
        let combined = (replies + comment.replies).filter { seen.insert($0.id).inserted }
        return CommentBranch.forest(combined, rootID: comment.id)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentContent(comment: comment, collapsed: $collapsed, count: comment.replyCount)
            if !collapsed {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(branches) { branch in CommentBranchView(branch: branch, depth: 1) }
                    if comment.replyCount > 0 && more {
                        Button {
                            request += 1
                        } label: {
                            Label(loadedPage == 0 ? "展开全部 \(comment.replyCount) 条回复" : "加载更多回复", systemImage: "arrow.turn.down.right")
                        }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).disabled(loading)
                    }
                    if loading { ProgressView().controlSize(.small) }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("重试回复") { request += 1 }.font(.caption).disabled(loading)
                    }
                }.padding(.leading, 18)
                    .overlay(alignment: .leading) {
                        Button { collapsed = true } label: {
                            RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2).frame(width: 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("折叠整个讨论").accessibilityLabel("折叠 \(comment.author) 的讨论")
                    }
            }
            Divider().opacity(0.5).padding(.top, 6)
        }.task(id: request) {
            guard request > 0 else { return }
            loading = true; error = nil
            do {
                let result = try await api.comments(aid: aid, page: loadedPage + 1, root: comment.id)
                guard !Task.isCancelled else { return }
                var seen = Set<Int64>()
                replies = (replies + result.comments).filter { seen.insert($0.id).inserted }
                loadedPage += 1; more = result.hasMore; loading = false
            } catch { if !Task.isCancelled { self.error = error.localizedDescription; loading = false } }
        }
    }
}

private struct CommentBranchView: View {
    let branch: CommentBranch
    let depth: Int
    @State private var collapsed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentContent(comment: branch.comment, collapsed: $collapsed, count: branch.descendantCount)
            if !collapsed && !branch.children.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(branch.children) { child in
                        AnyView(CommentBranchView(branch: child, depth: depth + 1))
                    }
                }.padding(.leading, depth < 4 ? 14 : 4)
                    .overlay(alignment: .leading) { Rectangle().fill(.quaternary).frame(width: 1) }
            }
        }.accessibilityElement(children: .contain)
    }
}

private struct CommentContent: View {
    let comment: Comment
    @Binding var collapsed: Bool
    let count: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "plus.circle" : "minus.circle").foregroundStyle(.tertiary)
                }.buttonStyle(.plain).help(collapsed ? "展开讨论" : "折叠讨论")
                    .accessibilityLabel("\(collapsed ? "展开" : "折叠") \(comment.author) 的评论")
                AvatarView(url: comment.avatar).frame(width: 20, height: 20)
                Text(comment.author).font(.caption.weight(.medium)).lineLimit(1)
                Spacer(minLength: 2)
                Text(comment.date, style: .relative).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if collapsed {
                Text(count > 0 ? "已折叠 · \(count) 条回复" : "已折叠评论").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(comment.text).font(.callout).lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("\(comment.likes)", systemImage: "hand.thumbsup").foregroundStyle(.secondary)
                    if count > 0 { Text("\(count) 条回复").foregroundStyle(.tertiary) }
                    Spacer()
                    Menu {
                        Button("复制评论") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(comment.text, forType: .string) }
                        Button("折叠讨论") { collapsed = true }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
                }.font(.caption2)
            }
        }
    }
}
