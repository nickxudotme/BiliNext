import BiliNextCore
import SwiftUI

struct FavoritePickerView: View {
    @ObservedObject var model: AppModel
    let aid: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [FavoriteSelection] = []
    @State private var selected = Set<Int64>()
    @State private var original = Set<Int64>()
    @State private var loading = true
    @State private var error: String?
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("收藏到文件夹").font(GlassTheme.readingFont.weight(.semibold))
            if loading { ProgressView() }
            if let error { Text(error).font(GlassTheme.metadataFont).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(folders) { folder in
                        Toggle(
                            folder.title,
                            isOn: Binding(
                                get: { selected.contains(folder.id) },
                                set: {
                                    if $0 {
                                        selected.insert(folder.id)
                                    } else {
                                        selected.remove(folder.id)
                                    }
                                })
                        )
                        .font(GlassTheme.bodyFont).frame(minHeight: GlassTheme.iconControlSize)
                    }
                }
            }
            if loaded && folders.isEmpty {
                Text("暂无收藏夹，请先在 B 站创建。").font(GlassTheme.bodyFont).foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                if !loaded && !loading { Button("重试") { Task { await load() } } }
                Button("保存") { save() }.buttonStyle(.borderedProminent).disabled(loading || !loaded)
            }.controlSize(.large).font(GlassTheme.labelFont)
        }.padding(24).frame(width: 360, height: 360).task { await load() }
    }
    private func load() async {
        guard let mid = model.profile?.id else {
            error = "请先登录"
            loading = false
            return
        }
        loading = true
        error = nil
        do {
            folders = try await model.api.favoriteSelection(mid: mid, aid: aid)
            original = Set(folders.filter(\.selected).map(\.id))
            selected = original
            loaded = true
        } catch { self.error = error.localizedDescription }
        loading = false
    }
    private func save() {
        loading = true
        error = nil
        Task { @MainActor in
            do {
                try await model.api.saveFavorites(
                    aid: aid, add: selected.subtracting(original),
                    remove: original.subtracting(selected))
                dismiss()
            } catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
