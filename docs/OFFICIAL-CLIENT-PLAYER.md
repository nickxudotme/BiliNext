# 本机官方客户端播放器检查

2026-10-05，只读检查 `/Applications/哔哩哔哩.app`。版本 1.19.0（1.19.0.5063），bundle ID `com.bilibili.bilibiliPC`。未修改官方客户端，未读其用户凭据或联网绕过访问限制。

## 直接证据

- `Contents/Frameworks/Electron Framework.framework`、`Contents/Resources/app.asar`：Electron 壳。ASAR 第一方网页资源临时提取到 `/tmp/bilinext-official-client-inspection`。
- `render/assets/lib/core.js`：内置播放器核心，metadata `nano: 4.10.2-ea1af62c (2026-09-10T16:10:53+08:00)`，文件 9,906,781 字节。SHA-256：`aebeca9c5d7d1c91f95e1852ef59b3bb25afd461aa126eafdc5e9a2af7ecce40`。
- `render/assets/player.e9082dd0.js`：从 `window.nano` 调用 `createPlayer`，配置有 `element`、`fullWrap`、`channelKind: ChannelKind.PC_APP`、`enableAV1`、`enableHEVC`、`appInfo`、`requestConfig`，返回实例挂到 `window.biliPlayer`。这是专用客户端接入，非 `player.bilibili.com/player.html` 外链页面。
- 同一文件监听 `Player_Play`、`Player_Pause`、`Player_LoadedMetadata`，调用播放器的 `getManifest`、`seek`、`setPlaybackRate` 等接口。
- 同一文件的下载桥接分支含 `download/getItemDmInfo`、`download/getItemRangeStream`、`download/getItemPlayerUrl`；窗口桥接含显示、可见性、关闭、全屏；登录 Cookie 通过 native bridge 接入。
- `render/assets/index.ef2cf61c.js`：缩略视频封装通过 `system/getPlayerInfo` 取 `playerSrc`；播放器不存在时加载核心，再调用 `createPlayer`。说明播放器核心与客户端界面可分离，但现有客户端仍提供宿主接口。
- `core.js` 内 `PC_APP = 7`，并分派到专用 `PCHelper`（webpack 模块 72545）；外链使用其他 Embedded channel。
- 弹幕实现存在 `dmList` / `cdmList`、预制文字图像 `img`、`drawImage`、`requestAnimationFrame`，以及 div/canvas 模式切换。核心还含 WebGL 和 Worker 代码，但不能仅据字符串数量断言普通滚动弹幕全部使用 WebGL 或 Worker。

## 当前判断与落地

可继续试验“薄宿主 + nano 核心”，保留官方弹幕和控制栏，Swift 接管宿主回调。需要实际验证 WKWebView 与 Chromium 的兼容性、请求/Cookie/Origin、OGV 和 UGC 获取播放地址、登录与窗口回调，以及进度事件。尚未运行这一核心接入原型，不能声称已复用成功。临时提取资源未放入项目发布资源。

当前先将 H5 后备从独立外链窗口改成主播放区域的官网视频页面，保留官方来源；CSS 只展示播放器，媒体事件回传 Swift 以联动 Transcript 和会话进度。此路线会受官网 DOM 变化影响，不能替代核心适配验证。

## 核心接入实测更新

用户明确选择客户端核心路线，官网页面嵌入已移除。新增 `OfficialClientResources`：在运行时只读解析本机安装包 ASAR 并取 `render/assets/lib/core.js`；该核心不进入 BiliNext 发布资源。新增 `OfficialClientPlayerView`：自己创建空播放器宿主，仅注入本地核心和接入代码，以 PC_APP channel 调用 createPlayer/connect；不加载官网的视频页 HTML。使用 BiliNext 现有登录会话的内存 Cookie，未读取官方客户端用户数据。

已在 BV1Tean6pEXo 验证核心加载、媒体连接、真实画面、官方控制栏、播放时间前进、点击 Transcript 从 3:02 跳到 2:17、切回原播放器时保持 2:24。没有外链回站/客户端引导。此项更新覆盖前文“尚未运行原型”的历史状态。仍待高密度弹幕、PGC、清晰度、全屏、弹幕发送及长时稳定性验收。当前优先 H264 兼容性，AV1/HEVC 未启用。

第二条 UGC `BV1s3H66CEZo`（Spark）也完成核心连接并连续播放，返回时长 4:13，官方弹幕“来啦”在播放器 DOM 中出现。AV1/HEVC 禁用后的核心宿主真实画面可见；尚无证据将此前官网页黑屏完全归因于编码或 CSS。
