# 原生 DASH 高画质播放

2026-10-10：保留 SwiftUI、AVPlayer 和两个现有播放器入口，新增原生分离流播放。

## 媒体链路

`BilibiliAPI.playback` 默认请求 `fnval=4048`、`fourk=1`，优先请求 1080P。解析器从实际下发视频段中选择档位，通过 VideoToolbox 查询 AV1 硬件解码能力；支持时优先 AV1，再选择 SDR HEVC／H.264，并独立选择 AAC 音频；没有对应实际流的目录档位不进入菜单。不支持 AV1 硬件解码的机器排除 AV1；HDR、杜比暂不进入原生菜单。

`DASHIndex` 解析 ISO BMFF sidx 的片段长度和时长。`DASHResourceLoader` 在随机端口的 **127.0.0.1** 上提供短期、随机路径的 VOD HLS 清单；视频与音频作为两个 rendition，由同一个 AVPlayer 管理时间线。初始化段和媒体片段按需从 CDN 读取，不转码、不保存完整文件、不启动外部进程，不引入 MPV 或 FFmpeg。

每个请求只能映射到当前媒体的已知片段，不能代理任意 URL；并发连接数和单片段大小有限制。`DASHHTTPClient` 在接收正文前检查 206、Content-Range 和长度，并限制正文累计长度；CDN 主地址失败会尝试备用地址。关闭、换标签、换分 P 和清晰度切换会取消旧加载并关闭旧监听器。

切换保留播放时间、暂停意图和倍速，快速连续切换只允许最新请求更新播放状态。索引准备失败或 AVPlayerItem 实际加载失败时按 AV1 → HEVC → H.264 尝试兼容编码，保持时间、暂停意图和倍速；H.264 索引准备失败时再尝试原来的单 MP4 路线。重试过程不重新开启已排除的编码，过期或官方核心的状态回调不触发原生重试。当前编码和单 MP4 都失败时显示错误；不承诺维持原档位。

下载功能显式请求单段 MP4，保持原有可带声音的完整文件格式。DASH 分轨下载合并不在此次范围内。本机官方核心的 enableAV1 配置也跟随硬件能力；此前硬编码 false 已移除。该核心的 AV1 实际播放尚未单独验收，以下 AV1 实测针对原生 AVPlayer。

## AV1 更新

本机 M3 Max 的 `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` 返回支持。在 `BV1p1n8zdEAk` 取得 `av01.0.00M.10.0.110.01.01.01.0` 的实际流，AVPlayerItemVideoOutput 取得 3840×2160 解码帧；30 秒拖动、1.5 倍速、暂停和换档通过，自动化全程静音。没有比较同画质 AV1/HEVC 的功耗或主观画质，不能据此宣称所有 AV1 源都更优。

运行时故障测试将 AV1 媒体替换为缺失文件，验证失败状态触发 HEVC 重载并继续播放；H.264 的 4K 流也验证实际播放。故障注入验证重试控制流，不代表遍历了所有损坏码流或网络故障。

## 验证记录

- 默认离线测试通过：25 项，5 项网络/账号测试默认跳过。新增覆盖实际档位与编码筛选、字段命名变体、静音视频、MP4 档位、索引 v0/v1、片段位置、截断/嵌套索引和 HTTP Range 验证。
- 全程静音的 AVPlayer 实测：公开样例 `BV1xx411c7mD` 实际下发 480P；现有登录状态的 `BV1dyaZ6gEwU` 实际下发 1080P 高码率。播放、30 秒拖动、1.5 倍速、暂停通过。
- 搜索“4K 风景”找到 `BV1p1n8zdEAk`，实际下发 qn=120，并通过 AVPlayerItemVideoOutput 取得 **3840×2160** 的解码帧；音频轨道启用检查通过。4K 播放、拖动、倍速、暂停及切至 720P 保留位置通过。
- 同一 4K 样例的 AppModel 集成测试在临时目录保存会话，验证自动播放、选 4K、暂停中切至 720P、快速连续切换至最终 1080P，并保持播放意图。测试复用已有登录状态，不执行点赞、投币、收藏等账号写操作。
- 格式检查、Debug / Release 编译、本机签名构建和签名验证通过。实际签名 App 保留了原有视频标签，`BV1ZQGk6DEZ9` 显示 1080P 并推进播放时间；4K 的完整切换验证使用上述 AVPlayer 和 AppModel 自动化测试。自动化播放全程静音。

复现：

```sh
swift test
BILINEXT_DASH_TEST=1 swift test --filter nativeDASHPlaybackSmoke
BILINEXT_DASH_TEST=1 BILINEXT_AUTH_PLAYBACK=1 BILINEXT_4K_TEST=1 \
  swift test --filter nativeDASHPlaybackSmoke
BILINEXT_DASH_TEST=1 BILINEXT_AUTH_PLAYBACK=1 BILINEXT_4K_TEST=1 BILINEXT_AV1_TEST=1 \
  swift test --filter nativeDASHPlaybackSmoke
```

可用 `BILINEXT_TEST_BVID` 指定公开样例。AUTH 开关会先检查现有登录是否有效；不开启不读取账号。4K 开关会搜索并要求找到实际下发的 4K 流，标题含“4K”本身不是通过依据。

尚未完成：数小时播放、所有视频/番剧的兼容矩阵、HDR/杜比、网络切换压力测试和主观口型同步检查（测试静音）。本轮确认的是实际解码及播放状态，不是这些范围全部验收。

HEVC 故障注入也已通过：暂停时替换为无法加载的 HEVC 项，自动回退到 H.264 后保持暂停。
