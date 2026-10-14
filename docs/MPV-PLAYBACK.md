# libmpv 播放内核

主播放页现在使用 libmpv，SwiftUI 控件、字幕、弹幕、窗口与标签页继续保留。每个播放标签有独立 MPVPlayer，切到其他页面暂停，关闭才释放。悬停预览仍为静音 AVPlayer。旧 AVPlayer / DASH 桥代码保留作兼容验证，不参与默认主播放路径。

MPVPlayer 直接接收原始视频和音频 URL，通过 mpv EDL 多轨格式加载，使用原有 Referer / User-Agent。启用 VideoToolbox 硬件解码，最多约 64 MiB 的前向缓存，目标 30 秒预读，网络等待 15 秒。实际缓存和硬解是否启用以 mpv 返回值为准。失败显示原有重新加载入口。

时间、时长、暂停与缓冲状态每 250ms 读取；弹幕调度直接读取 mpv 时间，保留原有 Core Animation 渲染。视频由 `MPVVideoLayer`（`CAOpenGLLayer`）在独立的串行渲染队列上用 libmpv render API 绘制：mpv 的更新回调合并成一次待渲染，先用 `mpv_render_context_update` 确认有新帧再画，不经过主线程，界面忙时视频不受影响。所有绘制都只在渲染队列上进行：图层缩放时 Core Animation 在主线程请求重画，这个请求会转交给渲染队列强制重画当前帧，而不是在主线程直接画。主线程从不等待渲染队列，因为渲染队列提交画面（`CATransaction.flush`）时要拿 Core Animation 的事务锁，主线程若在提交布局时等它就会死锁（2026-10-14 曾因此整窗卡死）。字幕识别的取帧也在渲染队列上异步完成。渲染上下文必须在 mpv 核心销毁前释放：`MPVSurface` 销毁时在渲染队列上异步释放，并持有播放器直到释放完成。（2026-10-14 前为 NSOpenGLView，每帧在主线程绘制。）OpenGL 属于 macOS 已弃用但仍可用的接口；后续可单独评估 Metal 渲染，当前不同时改写弹幕。

## 构建

开发依赖：`brew install mpv pkgconf`，提供 C 头文件和链接库。`swift build` / `swift test` 使用 pkg-config。

`bash scripts/build-app.sh` 把 libmpv 及运行库依赖复制到 App 内，重写为 @rpath 并逐个签名。优先使用本机 `/Applications/IINA.app/Contents/Frameworks/libmpv.2.dylib`；可用 `BILINEXT_MPV_LIBRARY` 指定已构建的兼容运行库。没有 IINA 时回退 Homebrew 库，但最低系统版本超过 macOS 26 的运行库会拒绝打包。IINA 原应用不修改。

本次 IINA 运行库为 mpv 0.41.0，44 个依赖库最低系统版本最高为 macOS 11。开发机 Homebrew 当前瓶装库要求 macOS 27，所以未用于最终 App。最低版本元数据已核对，尚未在另一台 macOS 26 机器实测。

参考 PiliPlus 的播放器组织与 mpv 官方接口，未复制 Flutter 源码。libmpv / FFmpeg 和各依赖自身的 GPL / LGPL 等许可仍适用；本次仅本机开发构建，对外分发前必须整理运行库对应的许可证与源码提供方式。独立实现 Swift 界面不改变这些运行库的许可义务。

参考：[mpv 手册](https://mpv.io/manual/master/)、[libmpv render API](https://github.com/mpv-player/mpv/blob/master/libmpv/render.h)、[PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)、[IINA](https://github.com/iina/iina)。

## 验证

31 个默认离线测试通过，8 个集成测试默认跳过；Debug / Release 编译、格式及 App 深度签名检查通过。实播测试均静音且不执行账号写操作：

- `BILINEXT_MPV_TEST=1 swift test --filter mpvDirectDASHPlaysSeeksSwitchesAndRetainsTabs`：连续 45 秒、独立音轨、跳转、2×、暂停、双实例和清晰度切换。
- `BILINEXT_MPV_TEST=1 swift test --filter playbackTabSwitchRetainsLoadedMedia`：AppModel + 实际 OpenGL 上下文，硬解、多标签暂停与同一实例保留、关闭释放，以及暂停状态切换清晰度和快速取消切换。
- 使用 IINA 运行库验证时设置 `DYLD_LIBRARY_PATH=/Applications/IINA.app/Contents/Frameworks`。
- 加上 `BILINEXT_MPV_4K_TEST=1` 的标签测试：3840×2160 AV1 实际解码与 VideoToolbox 硬解通过。
- App 实际检查：两个视频标签画面、超过六分钟连续播放、暂停、字幕跳转至 00:30、进入退出全屏。
- App 启动参数 `--mute` 仅将主播放测试静音；默认启动保留正常音量。

长时间弱网络、不同 CDN 的恢复以及所有视频编码尚不能由短时间实播保证。
