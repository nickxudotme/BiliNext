# SwiftFeedback

供 macOS Swift 项目使用的本地界面反馈原型：从应用菜单或应用内快捷键唤起，在原界面直接点选控件或自由圈画，填写修改意图，也可录制触发问题的操作，保存可供开发者和 coding agent 阅读的报告目录。

独立 Swift Package，无第三方依赖。当前要求 **macOS 14.4+、Swift 6 工具链**；包使用 Swift 5 language mode。支持 SwiftUI 和 AppKit，尚未提供 iOS 实现、MCP 服务或自动修改代码能力。

## 实际使用流程

菜单或快捷键唤起后，当前应用上方出现提示和右侧绿色工具条，不弹出独立截图编辑器。

- **点选**：悬停高亮目标，点击放下定位标记，在目标附近的反馈卡填写说明；可选择是否附带截图。
- **自由圈画**：直接拖动画笔，可追加多笔；底部说明条提供撤销、重做、取消与发送。圈画必须附带截图。
- **操作录制**：切换后标注层让出输入，只有紧凑的计时/停止条，继续操作应用来复现问题。最长 60 秒；停止或按 Esc 后进入说明卡，可预览时间线。
- **保存**：默认直接生成本地报告，显示回执，可查看目录或复制给开发助手的完整提示与报告路径。保存失败保留内容，支持重试/重新标注。

窗口尺寸变化时重新校准现场，并清除不再可靠的标注，保留已有问题说明。重新标注和退出是不同操作；圈画时 Esc 返回标注，录制时 Esc 停止并保留录制，其它编辑阶段 Esc 退出。

### 可选追问

默认不启用 AI 或预设问题；如宿主已有服务，可选择设置：

```swift
FeedbackCenter.shared.questionProvider = { description, elementName in
    // 调用宿主自己选择的服务；返回 nil 表示直接保存。
    // 涉及远端服务时，由宿主负责授权、隐私及凭据配置。
    FeedbackQuestion(text: "切换前在哪个页面？", suggestions: ["动态", "收藏"])
}
```

有问题时，反馈卡呈现对话、建议回答和「跳过并保存」；取消会取消未结束的提问任务。包内没有内置模型、账号或云端反馈服务。快捷分类标签单独记录问题类型，切换时保留用户原文；正文为空时不能发送。

## 添加依赖

将此目录作为本地包依赖加入宿主项目；Xcode 可通过 Add Local Package 添加。SwiftPM 示例：

```swift
dependencies: [
    .package(path: "Packages/SwiftFeedback")
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [.product(name: "SwiftFeedback", package: "SwiftFeedback")]
    )
]
```

包不会自行创建菜单、启动采集或限制构建类型。宿主决定何时启用；开发工具建议像 BiliNext 一样，把 import、配置、菜单、设置和组件标记入口放在 `#if DEBUG` 下。

## SwiftUI 接入

在主窗口出现时配置应用状态。`configure` 和界面 API 在主线程执行；状态闭包只在唤起反馈时调用，因此应返回已有的轻量状态，避免网络访问、磁盘扫描或耗时计算。

```swift
import SwiftUI
#if DEBUG
import SwiftFeedback
#endif

// 添加到宿主现有的主窗口内容：
ContentView()
    .onAppear {
        #if DEBUG
        FeedbackCenter.shared.configure {
            [
                "page.name": "library",
                "build.commit": "由宿主构建流程填入",
                "build.configuration": "debug"
            ]
        }
        #endif
    }
```

真实项目可在闭包中读取 model；捕获 class model 时可使用 `[weak model]`。若需要在暂时没有 key window 时指定回退主窗口，可在该窗口的根视图添加 `.background(FeedbackWindowReader())`。唤起时优先选择 key window，再选择这个回退窗口和 main window；因此从设置窗口唤起会反馈设置窗口。

### 菜单和快捷键设置

快捷键属于菜单动作，默认未设置，仅在当前应用内生效。下面两个视图共用 `FeedbackCenter.shared.shortcut`，修改会自动保存到宿主的 `UserDefaults`（键名 `SwiftFeedback.shortcut`）。

```swift
#if DEBUG
import SwiftFeedback

struct AppFeedbackCommands: Commands {
    @ObservedObject private var feedback = FeedbackCenter.shared

    var body: some Commands {
        CommandMenu("开发") {
            Button("反馈当前界面…") { feedback.present() }
                .keyboardShortcut(feedback.shortcut?.keyboardShortcut)
                .disabled(feedback.isCapturing)
            Button("打开反馈报告目录") { feedback.openReports() }
        }
    }
}

struct AppFeedbackSettings: View {
    @ObservedObject private var feedback = FeedbackCenter.shared

    var body: some View {
        Form {
            FeedbackShortcutSettings(shortcut: $feedback.shortcut)
            Button("打开反馈报告目录") { feedback.openReports() }
        }
        .padding()
    }
}
#endif
```

将 `AppFeedbackCommands()` 放入现有 Scene 的 `.commands { ... }`，将 `AppFeedbackSettings()` 放进现有设置页面；不需要再建一个 App。纯 SwiftUI 示例以上方 `import SwiftUI` 为前提。

录制器接受字母、数字或符号，至少包含 `⌘`、`⌃`、`⌥` 之一，可同时加 `⇧`；Esc 取消，离开设置窗口会取消录制。录制时检查当前应用菜单的快捷键冲突，不覆盖系统保留快捷键、宿主自定义事件处理器或今后才出现的菜单项的冲突检测。建议保留示例中的菜单标题，当前冲突检测以该标题识别反馈动作自身。

## 标记组件和源码位置

```swift
PlayerControls()
    .feedbackTarget("player.controls", label: "播放器控制栏", isActive: isCurrentPage)
```

默认参数会记录这次调用的 `#fileID` 和 `#line`。它定位到**组件注册处**，并不推断缺陷代码；源码行号对应当前构建，代码修改后应重新构建。为列表项使用稳定语义 ID，例如 `"video.card:\(video.id)"`；多个同名组件的实例另有 UUID 区分。

标记位置影响几何范围。例如只想标记 68 点高的工具栏，应在将它扩展到整页之前注册：

```swift
ToolbarView()
    .frame(height: 68)
    .feedbackTarget("browse.toolbar", label: "浏览工具栏")
    .frame(maxHeight: .infinity, alignment: .top)
```

为使用 `.opacity(0)` 保留的后台页面显式传 `isActive: false`；不能假定所有 SwiftUI 隐藏方式都能从 AppKit 层推断。标记使用不拦截鼠标和辅助功能的透明 NSView，并弱引用注册；在采集和点击事件命中时读取当前几何，不持续发布 SwiftUI 布局状态。

组件矩形按当前可见范围裁剪，单位是 point，原点位于**完整窗口左上角，包含标题栏**。点击时选择覆盖该点的最小已注册组件；没有已注册组件覆盖的区域返回 nil，仍然可以自由框选。注册一个大范围父组件，也会使其内部未单独标记的位置关联到父组件。

宿主若封装自己的 modifier，必须透传默认位置，避免所有反馈都指向包装函数：

```swift
extension View {
    @ViewBuilder
    func developmentTarget(
        _ id: String, label: String? = nil, isActive: Bool = true,
        file: String = #fileID, line: UInt = #line
    ) -> some View {
        #if DEBUG
        feedbackTarget(id, label: label, isActive: isActive, file: file, line: line)
        #else
        self
        #endif
    }
}
```

## AppKit 接入

同样先在主线程调用 `FeedbackCenter.shared.configure(contextProvider:)`。在现有菜单 action 中调用 `FeedbackCenter.shared.present()`；如果需要 SwiftUI 提供的录制界面，可用 `NSHostingView` 嵌入上面的 `AppFeedbackSettings`。

原生菜单需要将保存的快捷键同步给 `NSMenuItem`。例如在生命周期覆盖整个应用的菜单控制器中：

```swift
import AppKit
import Combine
import SwiftFeedback

@MainActor
final class FeedbackMenuController: NSObject {
    private var shortcutObservation: AnyCancellable?

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(
            title: "反馈当前界面…", action: #selector(showFeedback), keyEquivalent: ""
        )
        item.target = self
        shortcutObservation = FeedbackCenter.shared.$shortcut.sink { [weak item] shortcut in
            item?.keyEquivalent = shortcut?.key ?? ""
            item?.keyEquivalentModifierMask = NSEvent.ModifierFlags(
                rawValue: shortcut?.modifiersRawValue ?? 0
            )
        }
        return item
    }

    @objc private func showFeedback() {
        FeedbackCenter.shared.present()
    }
}
```

宿主保留 controller，并将返回的 item 加入自己的菜单；不需要安装全局按键监听。应用内直接赋值 `shortcut` 也应先检查其 `isValid`。

已有 NSView 可直接注册，不需要修改其绘制或输入实现：

```swift
let registry = FeedbackTargetRegistry.shared
let token = registry.register(
    view: controlsView, id: "player.controls", label: "播放器控制栏"
)

// 视图仍保留但不再是当前页面时：
registry.update(token, id: "player.controls", label: "播放器控制栏", isActive: false)

// 移除这个集成点时：
registry.unregister(token)
```

保存 token 以便更新或注销；`update` 保留实例 UUID。它的 `file`/`line` 默认记录更新调用处，如果需要保留首次注册位置，更新时显式传回原值。视图释放后弱引用不会阻止释放，下一次注册或快照会清理失效记录。可通过 `registry.snapshot(in: window)` 读取已注册区域，或用 `FeedbackTargetSnapshot.hitTest(point, in: snapshots)` 命中同一窗口左上坐标系中的点。

## 应用状态与事件

`contextProvider` 返回 `[String: String]`，用于页面、选择项、载入/错误状态、播放焦点、构建版本等宿主专有信息。包不反射整个 model，也不自动枚举偏好设置或请求内容。BiliNext 当前接入了工作区、页面、播放、字幕、mpv 属性和构建信息。

业务事件可以从任意线程追加：

```swift
FeedbackRecorder.shared.record("playback.seek", fields: [
    "videoID": videoID,
    "targetSeconds": String(targetSeconds),
    "reason": "keyboard"
])
```

共享 recorder 在内存中保留最近 200 条事件，事件名最多 160 字符，每个字段值最多 1,000 字符，不发布 SwiftUI 状态。`configure` 会添加应用内点击、非文本编辑状态下的按键编码/修饰键、窗口大小/全屏/焦点事件；反馈编辑器自身不进入该交互记录。业务事件仍由宿主主动提供，包不会自动拦截所有 API。录制期间还会采样宿主状态变化，并合并最近事件形成最多 2,000 条的时间线，包含程序触发的页面切换。

不要把 cookie、token、请求体或输入文本作为业务事件或 context 字段传入。自定义字段不会经过日志脱敏器。

## 报告内容

默认保存到 `FeedbackCenter.shared.reportDirectory`；普通非沙箱应用通常是 `~/Library/Application Support/<bundle identifier>/Feedback/`。每次保存生成独立目录，先写临时目录，成功后重命名。不存在上传步骤。

| 文件 | 内容 |
| --- | --- |
| `report.md` | 用户描述、选中组件和源码注册点、采集诊断、其余文件索引 |
| `context.json` | schema 版本、环境/窗口/焦点、宿主状态、组件区域、界面树、pin/画笔向量点、可选补充对话和诊断 |
| `events.json` | 唤起时截取的最近事件 |
| `logs.json` | 尽力读取的当前进程最近日志及脱敏后的消息 |
| `screenshot.png` | 当前窗口原始截图；截图失败时不生成 |
| `annotated.png` | 带定位标记或自由画笔的截图；截图失败时不生成 |
| `recording.json`、`recording/` | 可选操作录制：带时间戳的窗口 JPEG 序列和帧索引 |
| `replay.html` | 可选离线回看页面，与录制帧一起打开；不需要服务端 |

可直接把报告目录路径交给 coding agent，让其读取 `report.md`、JSON 和图片，结合当前源码定位问题。保存过程中锁定操作；成功后反馈卡变为回执，完成后重新唤起可创建新报告。

## 当前边界

- **源码映射需要轻量注册。** 不读取 SwiftUI 的私有视图结构，也不保证任意未标记控件都能精确定位源码。辅助功能树提供补充线索，但虚拟化、离屏元素和自绘控件可能不暴露完整内容。
- **截图来自系统窗口捕获。** 使用 ScreenCaptureKit 的当前进程窗口路径，不使用 `ImageRenderer` 重绘 SwiftUI；目标是保留混合 AppKit、播放器和玻璃材质的实际窗口内容。只请求指定窗口，不含阴影和子窗口；捕获失败会保留其余上下文并写明原因。特殊渲染、受保护内容和跨系统版本的效果仍需真机验证。
- **操作录制采用原生适配。** 原版用 rrweb 回放 DOM，macOS 原生控件没有 DOM；这里保存每秒最多一帧的真实窗口画面和交互/状态事件。最长 60 秒、最长边 1,280 像素、JPEG 总量 12 MB，单笔画笔最多 2,000 个采样点。不包含音频，也不是高帧率屏幕视频。录制期间仍可能出现帧失败，原因写入 recording.json。
- **截图和状态不是原子快照。** 应用状态、组件几何、AX 和异步截图并非原子采样，播放画面、滚动和动画可能在采集中推进。调整窗口大小会重置失效的标注并保留描述；采集过程中检测到几何变化会要求重新标注。这不检测所有内容变化。组件/选择矩形用窗口左上坐标，可访问性 frame 则使用 AppKit 屏幕全局左下坐标，JSON 环境字段记录了坐标约定。
- **采集有上限。** AX 默认最多 600 节点、24 层、文本 512 字符，并在 getter 之间检查 200 毫秒预算。大截图按最长边 8,192 像素及约 2,400 万像素上限缩小。主线程上的单次 AX getter 或宿主状态闭包仍可能耗时。
- **日志尽力采集。** 当前进程 OSLogStore 请求最近 120 秒，最多保存 200 条，扫描上限 10,000 条，并在枚举项之间检查一秒预算。日志可能尚未刷新，条目也可能截断或不可用；OSLogStore 初始化或单次访问没有硬性超时，仍可能延迟反馈窗口出现。原型不会读取任意系统进程日志。
- **本地报告仍可能含敏感信息。** 不读取剪贴板、浏览器存储、任意 UserDefaults 或可编辑 AX 文本值；OSLog 私有值保持系统脱敏，已知凭据字段整条替换，URL 参数会移除。截图、静态界面文字、未识别日志和宿主自定义字段仍可能包含私人内容，不能把这些规则理解为完整匿名化。分享报告前应检查实际文件。

## BiliNext 与验证

BiliNext 的入口是 `Sources/BiliNext/DevelopmentFeedback.swift`，菜单为「开发 → 反馈当前界面…」，设置页包含快捷键录制。接入由 `#if DEBUG` 控制；Release 不显示开发入口。BiliNext 的 `scripts/build-app.sh` 默认构建 Debug 应用，发行流程应使用其 Release 配置。

在包目录运行：

```sh
swift test
```

测试覆盖组件注册位置与窗口几何、可见性/实例生命周期、快捷键和冲突匹配、可访问性采集边界及日志脱敏、完整/无截图报告、Retina 标注像素方向和事件并发记录。是否能正确捕获当前播放器画面、玻璃效果和真实菜单/快捷键交互，还需要在签名后的宿主应用中验证；单元测试不等同于这部分验收。BiliNext 的实机范围见 [验收记录](../../docs/SWIFT-FEEDBACK.md)。

## 参考项目

产品交互参考 [makethisbetter-js](https://github.com/makethisbetter/makethisbetter-js) v1.30.1，使用流程对照见 [原生流程说明](../../docs/SWIFT-FEEDBACK-FLOW.md)。原项目以 MIT 发布，保留其 [许可文本](UPSTREAM-LICENSE)；这里使用原生 SwiftUI/AppKit 实现，不在宿主中嵌入 JavaScript SDK。

反馈卡片中的「出错 / 建议 / 疑问」为可选的单选类型标签，再次点击可取消；切换类型不会修改说明。类型单独写入 context.json 的 category（bug / suggestion / question）与 report.md。

## 语义事件与统一时间线

BiliNext 在 Debug 中记录浏览导航、打开视频、激活标签、请求跳转进度，以及清晰度请求/装载/失败事件。`Requested` 只表示操作意图；`qualityApplied` 表示播放器接受了新源，不保证已经渲染首帧，实际播放状态仍需结合状态采样和画面。语义事件不记录搜索文本、凭据或请求正文。

原生录制预览增加可点击事件列表，按实际秒数选择此前最近画面。导出的 replay.html 提供事件分类筛选、事件详情、状态前后值和该时刻的应用状态；将采集到的录制时段日志合并进 recording.json 的 timeline，原始 events.json、logs.json 仍独立保留。日志可能缺失或延迟，状态是最多每秒一次的采样，不代表所有中间状态。

播放按帧时间戳推进，缺帧时保留上一帧。没有更早画面时显示第一帧并明确显示画面时间；完全无画面时仍可查看事件和诊断。回放不执行原始业务操作，不发起远程请求。旧报告需要重新导出才能使用新回放界面。
