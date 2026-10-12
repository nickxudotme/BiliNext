import BiliNextCore
import SwiftUI

struct VideoActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 22)).frame(height: 30)
            Text(title).font(GlassTheme.metadataFont).lineLimit(1)
        }
        .frame(width: 36, height: 60)
        .contentShape(Rectangle())
    }
}

struct VideoActions: View {
    @ObservedObject var model: AppModel
    let video: Video
    @State private var liked = false
    @State private var coins = 0
    @State private var busy = false
    @State private var loaded = false
    @State private var coinDialog = false
    var body: some View {
        HStack(spacing: 8) {
            Button {
                performLike()
            } label: {
                VideoActionLabel(
                    title: liked ? "已赞" : "点赞",
                    systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
            }.help(liked ? "取消点赞" : "点赞").disabled(busy || (model.profile != nil && !loaded))
            Button {
                if model.profile == nil { model.loginPresented = true } else { coinDialog = true }
            } label: {
                VideoActionLabel(title: "投币", systemImage: coins > 0 ? "c.circle.fill" : "c.circle")
            }.help(coins > 0 ? "已投 \(coins) 枚硬币" : "投币").disabled(busy || coins >= 2)
        }.task(id: "\(video.bvid):\(model.profile?.id ?? 0)") {
            loaded = false
            liked = false
            coins = 0
            guard model.profile != nil else { return }
            do {
                let state = try await model.api.videoRelation(bvid: video.bvid)
                guard !Task.isCancelled else { return }
                liked = state.liked
                coins = state.coins
                loaded = true
            } catch {
                if !Task.isCancelled { model.toast = "互动状态加载失败：" + error.localizedDescription }
            }
        }
        .confirmationDialog("向这部视频投币", isPresented: $coinDialog) {
            Button("投 1 枚硬币") { performCoin(1) }
            if coins == 0 { Button("投 2 枚硬币") { performCoin(2) } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("B 站硬币投出后无法撤回，实际可投数量由视频规则决定。")
        }
    }
    private func performLike() {
        guard model.profile != nil else {
            model.loginPresented = true
            return
        }
        busy = true
        let desired = !liked
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.api.likeVideo(bvid: video.bvid, liked: desired)
                liked = desired
            } catch { model.toast = error.localizedDescription }
        }
    }
    private func performCoin(_ count: Int) {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await model.api.coinVideo(bvid: video.bvid, count: count)
                coins += count
                model.toast = "已投 \(count) 枚硬币"
            } catch { model.toast = error.localizedDescription }
        }
    }
}
