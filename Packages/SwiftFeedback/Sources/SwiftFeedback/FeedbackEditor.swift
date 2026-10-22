import AppKit
import SwiftUI

/// On-window tools deliberately leave the user's actual app visible underneath.
struct FeedbackEditor: View {
    @ObservedObject var session: FeedbackSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                FeedbackCanvas(session: session)
                    .accessibilityHidden(true)
                if session.phase != .receipt && session.phase != .saving && session.phase != .failed
                {
                    Text(session.phase == .drawing ? "继续圈画，也可以撤销笔画" : "点击标注，拖动绘制")
                        .font(.callout.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .feedbackGlass(in: Capsule())
                        .position(x: geometry.size.width / 2, y: 42)
                        .allowsHitTesting(false)
                    tools.position(x: geometry.size.width - 33, y: geometry.size.height / 2)
                }
                if session.phase == .drawing {
                    drawingBar
                        .frame(width: min(660, max(260, geometry.size.width - 40)))
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 44)
                }
                if [.composing, .clarifying, .saving, .receipt, .failed].contains(session.phase) {
                    let width = min(340, geometry.size.width - 32)
                    let height = min(cardHeight, geometry.size.height - 48)
                    FeedbackConversationCard(session: session)
                        .frame(width: width)
                        .frame(maxHeight: height)
                        .feedbackGlass(in: RoundedRectangle(cornerRadius: 20))
                        .position(cardPosition(size: geometry.size, width: width, height: height))
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
        .tint(FeedbackStyle.green)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: session.phase)
        .sheet(isPresented: $session.showReplay) {
            if let recording = session.recording { FeedbackReplayView(recording: recording) }
        }
    }

    private var cardHeight: CGFloat {
        switch session.phase {
        case .receipt: 248
        case .saving: 180
        case .failed: 270
        case .clarifying: 460
        default: session.recording == nil ? 340 : 385
        }
    }

    private func cardPosition(size: CGSize, width: CGFloat, height: CGFloat) -> CGPoint {
        if session.phase == .receipt { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let anchor =
            session.pin?.cgPoint
            ?? CGPoint(x: size.width - width - 80, y: size.height - height - 80)
        let rect = session.selectedElement?.frame
        var x = (rect?.midX ?? anchor.x) - width / 2
        var y = (rect?.maxY ?? anchor.y) + 16
        if y + height > size.height - 20 { y = max(24, (rect?.minY ?? anchor.y) - height - 16) }
        x = min(max(16, x), size.width - width - 16)
        y = min(max(24, y), max(24, size.height - height - 24))
        return CGPoint(x: x + width / 2, y: y + height / 2)
    }

    private var tools: some View {
        VStack(spacing: 8) {
            Button {
                session.markupMode()
            } label: {
                Image(systemName: "scope").frame(width: 34, height: 34)
                    .background(
                        FeedbackStyle.green.opacity(
                            session.phase == .annotating || session.phase == .drawing ? 0.14 : 0),
                        in: Circle()
                    )
                    .foregroundStyle(
                        session.phase == .annotating || session.phase == .drawing
                            ? FeedbackStyle.green : .primary)
            }.help("标注 · 点击定位，拖动圈画").accessibilityLabel("标注")
            Button {
                session.beginRecording()
            } label: {
                Image(systemName: "video").frame(width: 34, height: 30)
            }.help("录制触发问题的操作，最长 60 秒").accessibilityLabel("操作录制")
            Menu {
                ForEach(session.context.targets) { target in
                    Button(target.label) { session.select(target) }
                }
            } label: {
                Image(systemName: "list.bullet").frame(width: 34, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("使用键盘选择组件").accessibilityLabel("选择组件")
            .disabled(session.phase != .annotating)
            Rectangle().fill(.separator).frame(width: 20, height: 1)
            Button {
                session.close?()
            } label: {
                Image(systemName: "xmark").frame(width: 34, height: 30)
            }
            .help("退出反馈 · Esc").accessibilityLabel("退出反馈")
        }
        .font(.body.weight(.medium)).buttonStyle(.plain).foregroundStyle(.primary)
        .padding(.horizontal, 6).padding(.vertical, 10)
        .feedbackGlass(in: Capsule())
        .disabled(session.phase == .clarifying)
    }

    private var drawingBar: some View {
        HStack(spacing: 12) {
            TextField("给圈画添加说明", text: $session.description)
                .textFieldStyle(.plain).onSubmit { session.submit() }
                .accessibilityLabel("圈画说明")
            Button {
                session.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(session.strokes.isEmpty).help("撤销笔画").accessibilityLabel("撤销笔画")
            Button {
                session.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(session.redoStrokes.isEmpty).help("重做笔画").accessibilityLabel("重做笔画")
            Label("截图", systemImage: "checkmark.square.fill").font(.caption).foregroundStyle(
                .secondary
            )
            .help("圈画会随截图一起保存")
            Divider().frame(height: 20)
            Button("取消") { session.markupMode() }
            Button("发送") { session.submit() }.buttonStyle(.borderedProminent)
                .disabled(session.strokes.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .font(.callout).buttonStyle(.plain).padding(12)
        .feedbackGlass(in: RoundedRectangle(cornerRadius: 20))
    }
}

enum FeedbackStyle {
    static let green = Color(red: 0.016, green: 0.47, blue: 0.34)
}

private struct FeedbackConversationCard: View {
    @ObservedObject var session: FeedbackSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.phase == .receipt {
                receipt
            } else {
                header
                switch session.phase {
                case .saving:
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在整理反馈…").font(.callout.weight(.medium))
                            Text(session.capture == nil ? "正在补齐窗口现场与进程日志" : "正在保存标注和上下文")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                case .failed: failure
                case .clarifying: clarification
                default: composer
                }
            }
        }
        .onAppear { focused = true }
        .onChange(of: session.phase) { focused = true }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 25, height: 25).background(
                    FeedbackStyle.green, in: RoundedRectangle(cornerRadius: 7))
            Text("Make This Better").font(.callout.weight(.semibold))
            Spacer()
            if session.phase != .saving {
                Button {
                    session.close?()
                } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭反馈")
            }
        }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let element = session.selectedElement {
                Label(String(element.name.prefix(70)), systemImage: "scope")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 8) {
                ForEach(FeedbackCategory.allCases, id: \.self) { category in
                    categoryTag(category)
                }
            }
            if let recording = session.recording {
                Button {
                    session.showReplay = true
                } label: {
                    HStack {
                        Image(systemName: "play.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("操作录制 · \(Int(recording.duration.rounded())) 秒").font(
                                .callout.weight(.medium))
                            Text("\(recording.frames.count) 帧窗口画面 · 点击预览").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }.padding(10).background(
                        FeedbackStyle.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                }.buttonStyle(.plain).accessibilityLabel("预览操作录制")
            }
            ZStack(alignment: .topLeading) {
                if session.description.isEmpty {
                    Text("描述问题或建议…").foregroundStyle(.tertiary).padding(.top, 7).padding(
                        .leading, 5
                    ).allowsHitTesting(false)
                }
                TextEditor(text: $session.description).scrollContentBackground(.hidden)
                    .focused($focused).accessibilityLabel("反馈内容")
            }.font(.body).frame(height: 86)
            HStack {
                if session.recording == nil {
                    Toggle(isOn: $session.includeScreenshot) { Label("截图", systemImage: "camera") }
                        .toggleStyle(.checkbox).font(.caption).help("同时保存当前窗口截图")
                }
                Spacer()
                Text("⌘↩").font(.caption2).foregroundStyle(.tertiary)
                Button("发送") { session.submit() }.buttonStyle(.borderedProminent)
                    .disabled(
                        session.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.return, modifiers: .command)
            }
            details
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private func categoryTag(_ category: FeedbackCategory) -> some View {
        let selected = session.category == category
        return Button {
            session.toggleCategory(category)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
                Text(category.title)
            }
        }
        .font(.caption).buttonStyle(FeedbackCategoryButtonStyle(selected: selected))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(selected ? "取消此类型" : "标记反馈类型，保留已输入内容")
    }

    private var clarification: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.description).font(.callout).padding(12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .background(
                    FeedbackStyle.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            if let question = session.question {
                Text(question.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                ForEach(question.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { session.finishAnswer(suggestion) }
                        .font(.caption).buttonStyle(.bordered)
                }
                TextField("补充说明后发送", text: $session.answer, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4).focused($focused)
                    .accessibilityLabel("补充说明")
            } else if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("正在完善反馈…").font(.caption)
                }
            }
            HStack {
                Button("跳过并保存") { session.finishAnswer("") }.buttonStyle(.plain).font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("发送") { session.finishAnswer() }.buttonStyle(.borderedProminent)
                    .disabled(
                        session.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 16).padding(.bottom, 16)
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("暂时无法保存", systemImage: "exclamationmark.triangle").font(.headline)
            Text("你的描述和标注仍在，重试即可。").font(.callout)
            Text(session.error ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("重试保存") { session.save() }.buttonStyle(.borderedProminent)
                Button("重新标注") { session.restartMarkup() }.buttonStyle(.bordered)
            }
        }.padding(18)
    }

    private var receipt: some View {
        VStack(spacing: 13) {
            Image(systemName: "checkmark").font(.title2.weight(.semibold))
                .foregroundStyle(FeedbackStyle.green).frame(width: 48, height: 48)
                .background(FeedbackStyle.green.opacity(0.10), in: Circle())
            Text("反馈已保存，谢谢。").font(.headline)
            Text("描述、标注和运行上下文已整理到本机。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 15) {
                Button("查看报告") {
                    if let url = session.savedURL {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button("复制给开发助手") {
                    guard let url = session.savedURL else { return }
                    let prompt =
                        "请检查这条界面反馈：\n\(url.path)\n先读取 report.md、context.json、events.json 和图片；如有 recording.json，请结合录制帧与操作时间线分析。核对当前源码与报告构建信息，再定位问题并给出修改。"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }
            }.font(.caption).buttonStyle(.link)
            Button("完成") { session.close?() }.buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut(.cancelAction)
        }.padding(24).frame(maxWidth: .infinity)
    }

    private var details: some View {
        DisclosureGroup("现场信息", isExpanded: $session.showDetails) {
            VStack(alignment: .leading, spacing: 5) {
                if let source = session.selectedElement?.source {
                    Text("\(source.file):\(source.line)").font(.caption.monospaced()).textSelection(
                        .enabled)
                }
                Text(
                    "\(session.context.targets.count) 个源码区域 · \(session.context.accessibility.count) 个界面节点 · \(session.context.application.count) 项状态"
                )
                Text(
                    session.capture == nil
                        ? "正在补齐截图与日志，你可以继续描述。"
                        : "\(session.events.count) 条操作 · \(session.capture?.logs.count ?? 0) 条进程日志")
                if let capture = session.capture, capture.image == nil {
                    Text("截图未获得，其余上下文仍会保存。").foregroundStyle(.orange)
                }
                ForEach(Array(session.context.diagnostics.enumerated()), id: \.offset) {
                    _, message in
                    Text(message).lineLimit(3)
                }
            }.font(.caption2).foregroundStyle(.secondary).frame(
                maxWidth: .infinity, alignment: .leading)
        }.font(.caption).foregroundStyle(.secondary)
    }
}

struct FeedbackRecordingBar: View {
    @ObservedObject var session: FeedbackSession
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 14) {
                Circle().fill(.red).frame(width: 7, height: 7)
                let seconds = min(
                    60,
                    max(
                        0,
                        Int(
                            timeline.date.timeIntervalSince(
                                session.recordingStartedAt ?? timeline.date))))
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                Text("操作录制").foregroundStyle(.secondary)
                Button("停止") { session.stopRecording() }.buttonStyle(.borderedProminent).tint(
                    FeedbackStyle.green
                )
                .accessibilityLabel("停止操作录制")
                Button {
                    session.close?()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain).accessibilityLabel("取消录制")
            }.font(.callout).padding(12).feedbackGlass(in: Capsule())
        }
    }
}

private struct FeedbackReplayView: View {
    let recording: FeedbackRecording
    @Environment(\.dismiss) private var dismiss
    @State private var position: Double = 0
    private var frame: FeedbackRecording.Frame? {
        recording.frames.last(where: { $0.offset <= position }) ?? recording.frames.first
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("操作录制").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    if let frame, let image = NSImage(data: frame.jpeg) {
                        Image(nsImage: image).resizable().scaledToFit().frame(
                            maxWidth: .infinity, maxHeight: .infinity)
                        Slider(value: $position, in: 0...max(0.01, recording.duration))
                            .disabled(recording.duration <= 0).accessibilityLabel("录制时间线")
                        Text(
                            "\(String(format: "%.2f", position)) / \(String(format: "%.2f", recording.duration)) 秒 · 画面 \(String(format: "%.2f", frame.offset)) 秒"
                        )
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        ContentUnavailableView(
                            "没有获取到窗口画面", systemImage: "photo.badge.exclamationmark",
                            description: Text("操作事件仍会随报告保存。"))
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(recording.events.enumerated()), id: \.offset) { _, event in
                            Button {
                                position = min(
                                    recording.duration,
                                    max(0, event.timestamp.timeIntervalSince(recording.startedAt)))
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        String(
                                            format: "%.2fs · %@",
                                            event.timestamp.timeIntervalSince(recording.startedAt),
                                            event.name)
                                    )
                                    .font(.caption.weight(.medium))
                                    Text(
                                        event.fields.keys.sorted().map {
                                            "\($0): \(event.fields[$0] ?? "")"
                                        }.joined(separator: " · ")
                                    )
                                    .font(.caption2).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8).background(
                                        .primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(width: 250)
            }
            Text("每秒最多一帧窗口画面；点击事件定位到此前最近画面，无更早画面时显示第一帧。不包含音频。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width: 900, height: 540).tint(FeedbackStyle.green)
    }
}
