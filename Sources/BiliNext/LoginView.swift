import BiliNextCore
import CoreImage.CIFilterBuiltins
import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var status = "正在生成二维码…"
    @State private var retry = UUID()
    @State private var failed = false
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("登录 B 站").font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).accessibilityLabel("关闭")
            }
            Text("使用哔哩哔哩手机客户端扫码确认").foregroundStyle(.secondary)
            Group {
                if let image {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView()
                }
            }.frame(width: 220, height: 220)
            Text(status).font(.callout).multilineTextAlignment(.center)
            if failed { Button("刷新二维码") { retry = UUID() }.buttonStyle(.glass) }
            Text(model.credentialNotice).font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 380)
            .task(id: retry) { await login() }
    }
    private func login() async {
        failed = false
        image = nil
        status = "正在生成二维码…"
        do {
            let code = try await model.api.loginCode()
            guard !Task.isCancelled else { return }
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(code.url.utf8)
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
                let cg = CIContext().createCGImage(output, from: output.extent)
            {
                image = NSImage(cgImage: cg, size: NSSize(width: 220, height: 220))
            }
            status = "等待扫码"
            for _ in 0..<90 {
                try await Task.sleep(for: .seconds(2))
                let result = try await model.api.pollLogin(code.key)
                try Task.checkCancellation()
                switch result {
                case .waiting: status = "等待扫码"
                case .scanned: status = "已扫码，请在手机上确认"
                case .expired:
                    status = "二维码已过期"
                    failed = true
                    image = nil
                    return
                case .success:
                    await model.loggedIn()
                    return
                }
            }
            status = "二维码已过期"
            failed = true
            image = nil
        } catch is CancellationError {} catch {
            if !Task.isCancelled {
                status = error.localizedDescription
                failed = true
                image = nil
            }
        }
    }
}
