# Swift 播放与评论渲染优化

2026-10-10，macOS 27.0.1 / Apple M3 Max / 120Hz。

## 问题与改动

播放观察器每 0.25 秒写入 AppModel.time、playing、duration 与 buffering。ObservableObject 会在每次 Published 赋值时通知所有观察者，即使状态未变，外壳、浏览与评论都接收更新。改为内部 PlaybackClock 发布时间，只有播放器与字幕观察它；播放状态、时长和缓冲状态仅在变化时发布。弹幕列表只订阅去重后的 6 分钟段编号。每 5 秒会话保存使用快照，不改 Published 标签数组；关闭、切换、退出等交互保存仍会更新内存标签及原 JSON。

评论回复树原先在每次 body 求值时合并并重建。现在仅在评论首次出现和回复页返回后重建；评论根 / 父节点、孤儿回复与折叠交互保持原行为。字幕定位也将当前字幕 ID 集合先算一次，避免逐组查找时重复扫描完整字幕。

旧弹幕使用 CADisplayLink 在显示器刷新频率下逐条移动 CATextLayer；每个图层有动态阴影与栅格化。新版将文字及阴影预绘制为透明 CGImage，使用普通 CALayer 和线性 CABasicAnimation 移动。调度器最多 30Hz，负责弹幕入场离场及跳转、暂停、缓冲、倍速、尺寸变化时重新同步，正常调度不重写已有弹幕的位置动画。文字位图复用，缓存上限 512 项 / 32MiB。调度频率不是弹幕动画的显示帧率，图层移动由系统合成器完成。

源文件：PlaybackClock.swift、DanmakuSurface.swift、AppModel.swift、VideoCommunityView.swift；BiliNextCore 公共接口、播放后端、窗口和存储格式没有改变。

## 验证

- 默认 swift test：16 项离线测试通过（11 核心 + 5 应用），4 项集成测试跳过。
- 新测试验证连续 40 个时间更新不通知全局 AppModel；相同播放状态不重复发布，非法时间安全归零。
- 新渲染测试验证 CGImage 内容、没有 CATextLayer / 动态阴影、普通 tick 保留图层位置与动画、暂停移除移动动画、前后跳转正确增删弹幕。
- Debug / Release 编译、格式检查、签名 App 构建与 codesign --verify --strict 通过。Release 编译仍有原有钥匙串接口弃用警告。
- 打包 App 使用 BV1Qi546YE5U 实际播放，观察到滚动和顶部彩色弹幕且文字方向正常；评论播放中滚动、完整回复、折叠与展开成功。暂停状态显示播放按钮；重启读取约 7:58 位置；字幕实际加载中文，点击 0:07 后进度到 7.46 秒。
- 前后各取 5 秒 sample。改动前采样中 SwiftUI GraphHost.flushTransactions、控件更新与评论构造占据明显主线程路径；优化后看到大量运行循环等待，弹幕文字绘制集中在新图层入场。原始诊断在本机 /tmp/bilinext-before-render.sample 和 /tmp/bilinext-after-render.sample，不提交。

## 限制

采样时视频位置、倍速和交互状态不同，不能据此报告可靠的 CPU 降幅或帧率提升百分比。本轮没有 Instruments 帧耗时分布、GPU 合成指标或长时间高密度弹幕基准，不宣称已经消除全部卡顿。

CUA 期间有窗口捕捉与焦点错误，关闭 / 撤销标签未取得可靠确认；它们需要继续人工回归。不同倍速、不同屏幕缩放、后台 / 前台切换、官方核心和长回复列表的持续滚动也需要后续验收。官方核心采用相同的时间更新隔离，但这次没有单独做官方核心播放对照。
