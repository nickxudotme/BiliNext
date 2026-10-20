import SwiftUI

struct PerformanceHUDOverlay: View {
    @AppStorage("developer.performanceHUD") private var enabled = false
    var body: some View {
        if enabled { PerformanceHUD().padding(.top, 76).padding(.trailing, 16) }
    }
}

private struct PerformanceHUD: View {
    @StateObject private var monitor = PerformanceMonitor()
    var body: some View {
        let value = monitor.snapshot
        VStack(alignment: .leading, spacing: 4) {
            Text("性能监测 · 近 2 秒").fontWeight(.semibold)
            Text(
                String(
                    format: "回调 %.1f Hz  ·  屏幕上限 %d Hz", value.callbacksPerSecond,
                    value.screenMaximum))
            Text(
                String(
                    format: "间隔 P95 %.1f ms  ·  最差 %.1f ms", value.p95Milliseconds,
                    value.worstMilliseconds))
            Text(
                String(format: "迟到 %.1f ms  ·  超预算 %d 次", value.lateMilliseconds, value.overBudget))
            Text("回调频率 ≠ 实际渲染 FPS").foregroundStyle(.white.opacity(0.65))
        }
        .font(.system(size: 11, design: .monospaced)).monospacedDigit()
        .foregroundStyle(.white).padding(10)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
        .background { PerformanceDisplayLink(monitor: monitor).frame(width: 0, height: 0) }
        .allowsHitTesting(false)
    }
}
