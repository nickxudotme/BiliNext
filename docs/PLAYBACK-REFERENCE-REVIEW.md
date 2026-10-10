# 本地同类项目播放实现对照

日期：2026-10-10。依据工作区当前源码进行只读研究；没有运行参考客户端，没有使用真实账号执行写操作。重点是本轮 720P 问题，以及与之相关的切换、字幕和弹幕生命周期，不是对所有功能逐项验收。

后续实施更新：Swift 已新增原生 DASH → 本机 HLS 接入，并实测 4K。下文保留研究时的基线判断；最新行为与验证见 [原生 DASH 播放记录](NATIVE-DASH-PLAYBACK.md)。

## 结论

当前限制首先在媒体接入层。Swift 和 Electron 正式版都请求 `fnval=1`、`platform=html5`，只接受单段 `durl` MP4。高画质参考实现则请求 DASH，分别选择视频、音频，再交给支持分离流的播放内核。仅提高 `qn` 或换 UI 框架不足以补齐这条链路。

720P 是当前请求实际返回的档位，不能据此断言视频最高只有 720P，也不能断言账号没有更高画质权限。此前已修正错误提示，高画质播放能力仍待实现。

## 逐项对照

| 项目 | 已查看的实现 | 值得借鉴 | 使用边界 |
| --- | --- | --- | --- |
| PiliPlus / Flutter | `lib/http/video.dart:218` 请求 `fnval=4048`、`fourk=1`；`lib/pages/video/controller.dart:680` 切换前记录播放位置；`lib/plugin/pl_player/controller.dart:905` 用 MPV EDL 组合视频和音频 | API、选流、播放器配置分开；切换保留时间；字幕按需加载并缓存 | 高画质能力来自媒体链路，不是 Flutter 自带。它的 `updatePlayer` 会开启自动播放，Swift 应继续保留用户原先暂停状态 |
| Bili.Copilot / C# WinUI | `src/Desktop/BiliCopilot.UI/Resolvers/VideoMediaSourceResolver.cs:43` 默认档位选择；`:86` Cookie/Referer 与 MPV 配置；`:176` 按档位和编码挑选视频、独立音轨 | 记住用户档位、编码偏好；媒体解析与视图分开；视频和音频分别处理 | `ViewModels/Items/SourceItemViewModel.cs:22` 按 VIP 标记判断启用，不宜直接作为我们判断实际流可用性的依据；API 请求在依赖服务中，本轮未确认其内部全部实现 |
| BBHouse / Qt + MPV | `app/core/PlayerApi.cpp:217` DASH 请求；`:335` 档位目录和实际视频段交叉检查；`app/player/MpvClient.cpp:195` 主视频加载后加音轨；`:364` 音频候选重试与请求代次检查 | 实际流决定可选档位；主/备用 CDN；旧请求不污染新视频；加载顺序明确 | 最贴近本轮故障处理需求，但 MPV 命令和 Qt 生命周期不能直接搬进 AVPlayer |
| bilibili-api / Python | `bilibili_api/video.py:548` HTML5 MP4 与 DASH 请求区别；`:2561` 按画质、编码、HDR、杜比筛选实际流 | 完整媒体响应模型、明确流类型、独立视频/音频筛选 | API 库不负责实时播放；选出 AV1/HDR 不代表当前播放设备能解码或正确显示 |
| BiliNextDesktop / Electron | `src/main/api.ts:345` 同样限定单段 MP4 | 可复用已有业务边界经验 | 和 Swift 共享兼容范围，没有独立解决 DASH；不能用它证明高画质已实现 |
| 自建 Flutter / Electron 原型 | `prototypes/CrossPlatformPlayer/DECISION.md`、`prototypes/ElectronPlayer/VALIDATION.md`、两端播放器源码 | 弹幕位图缓存、独立渲染时钟、本地压力测试方法 | 本地视频原型不验证网络 DASH、账号权益、长期同步，也不能推出框架性能排名；SidebarStudy 是侧栏外观原型，不是播放参考 |

上述路径相对于工作区根目录；PiliPlus、Bili.Copilot、BBHouse、bilibili-api 的 LICENSE 均为 GPLv3。后续借鉴行为与设计并自行实现；若复制或集成其代码，需单独处理对应许可要求。

## 对 Swift 版的具体启发

1. **先建完整响应模型。** 单段 MP4 与 DASH 分开表示；视频段携带档位、编码、分辨率、主/备用地址，音频段单独建模。`accept_quality` 是档位目录，菜单是否可用还需检查实际下发流及播放内核兼容性。
2. **分清三种结果。** 请求档位、服务器实际下发档位、内核实际播放档位分别记录。明确区分媒体格式不支持、账号/服务端未下发、CDN 失败、解码失败，避免统一提示“最高 720P”。
3. **维持 SwiftUI 界面，验证媒体路线。** 当前 `Sources/BiliNext/MediaResourceLoader.swift:1` 已处理单个资源的 HTTP Range、Referer 和 User-Agent，但没有音视频组装或备用地址切换。DASH 接入需要补足这些能力，不能只将视频 URL 替换进去。
4. **切换是一个完整事务。** 记录当前位置、暂停状态、倍速；加载新媒体和音轨，定位完成再恢复；用加载代次取消过期结果；同步更新字幕和弹幕时间基准。PiliPlus 保留时间、BBHouse 检查代次的做法可结合使用。
5. **字幕和弹幕保持独立。** PiliPlus 视频控制器的字幕按需缓存、Copilot 的独立 SubtitleViewModel、BBHouse 的独立 DanmakuEngine 都体现这条边界。BBHouse 还按暂停、可见性、窗口暴露状态停止动画，并将异步合并结果按版本校验；可用于继续审查我们的后台标签和隐藏窗口资源消耗。

## 推荐后续实施顺序

- 离线解析测试：单 MP4、DASH、目录有档位但无对应流、编码不兼容、无音频、备用地址、异常响应。
- 小范围验证原生 AVFoundation 的分离媒体播放方案。先用 1080P H.264 + AAC 验证连续播放、同步、拖动、暂停切换和倍速；组装方式仍需实验，现有代码不能证明可行。不把两个独立播放器当成同步方案。
- 原生方案满足验证后再扩展高帧率、4K、HEVC 和 HDR，并保留 MP4 回退。
- 若原生路线无法可靠满足串流和跳转，再评估嵌入 MPV 的打包、签名、许可与资源成本，并明确选择。参考项目证明它是一条路线，不构成自动更换内核的决定。

实际验收还需要公开视频和已有登录状态下的只读播放验证，包括真实下发档位、音画同步、拖动、切换、字幕跳转以及长时间播放。本轮仅完成源码研究和此记录，没有完成这些运行验证，也没有改变播放器架构。
