<p align="center">
  <img src="docs/images/icon.png" width="128" alt="BiliNext 图标">
</p>

<h1 align="center">BiliNext</h1>

<p align="center">使用 SwiftUI 与 AppKit 构建的原生 macOS 哔哩哔哩客户端。</p>

<p align="center">
  <a href="https://github.com/nickxudotme/BiliNext/releases">下载与更新</a> ·
  <a href="docs/DEVELOPMENT.md">本地开发</a> ·
  <a href="LICENSE">GPL-3.0</a>
</p>

BiliNext 将视频浏览、播放、弹幕和字幕阅读整合在原生 Mac 窗口中，支持多标签播放、系统媒体控制与本地续播。主播放器采用 libmpv，界面使用 SwiftUI 与 AppKit 实现。

本项目是独立开发的第三方客户端，与哔哩哔哩官方无关联。

## 安装

支持 **Apple Silicon（M 系列芯片）**，需要 **macOS 26 或更新版本**，以及 [Homebrew](https://brew.sh/)。

```sh
brew install nickxudotme/tap/bilinext
```

Homebrew 会自动识别 cask 并安装 mpv 等依赖。安装完成后，从「应用程序」打开 BiliNext，扫码登录即可使用需要账号的功能。

应用目前尚未经过 Apple 公证，安装过程不会自动移除下载隔离标记。如果 macOS 阻止打开，请先查看 Homebrew 显示的说明，再在终端手动执行其中针对 BiliNext 的完整命令；如出现 `Password:`，请在终端输入 Mac 管理员密码，输入时不会显示字符。登录状态保存在系统钥匙串中，升级后可能需要重新授权。

[GitHub Releases](https://github.com/nickxudotme/BiliNext/releases) 也提供 ZIP 安装包。当前安装包依赖 Homebrew 的 mpv，不是包含全部运行库的独立安装包；建议通过上述命令安装。

## 更新与卸载

更新：

```sh
brew update
brew upgrade nickxudotme/tap/bilinext
```

卸载：

```sh
brew uninstall nickxudotme/tap/bilinext
```

## 功能

### 浏览与收藏

- 首页推荐、热门、排行榜，关键词与 BV／视频链接搜索。
- 关注动态、关注直播，番剧、国创、纪录片、电影和电视剧索引。
- UP 主个人页、投稿、合集、系列及关注操作。
- 收藏夹管理、稍后再看、云端历史，以及视频和评论点赞、投币入口。
- 评论最热／最新排序、树状回复、分页与回复定位。

### 播放与弹幕

- 多标签播放、后台打开、关闭撤销、标签恢复与本地续播。
- 清晰度、倍速、音量、视频编码与音轨偏好，支持分 P／合集自动连播。
- 剧场与全屏模式，可调整或隐藏的播放信息栏。
- 接入系统「正在播放」，支持媒体键、耳机按键和系统播放进度控制。
- 滚动、顶部与底部弹幕，支持字号、透明度、显示区域、速度和关键词过滤。
- 直播播放、实时聊天弹幕、暂停与重连。
- 当前分 P 的单段 MP4 下载、进度显示、取消与重试。

### 字幕阅读

- 字幕脚本搜索、逐句／段落阅读、跟随播放、点击跳转与全文复制。
- [双语字幕](docs/BILINGUAL-SUBTITLES.md)：同时显示两条现有字幕轨，各自按时间同步，默认保留源字幕换行。
- [智能字幕](docs/SMART-SUBTITLES.md)：本机识别画面硬字幕，在重复时自动隐藏软字幕，并支持手动调整。

## 当前限制

BiliNext 仍在持续开发，尚未覆盖官方客户端的全部功能。

- 清晰度和番剧播放受实际视频源、账号权限及地区限制影响。默认请求 1080P，有源且有权限时可选择 4K。
- 已登录账号的原生普通视频播放支持云端历史同步；番剧和可选官方播放器核心的历史上报尚未覆盖。
- 暂不支持私信、投稿、发布动态、评论回复与弹幕发送。
- 暂不支持 HDR／杜比画面、DASH 分轨下载合并、下载断点续传、DLNA 和 WebDAV。
- 可选的本机官方播放器核心需要已安装兼容的哔哩哔哩官方客户端，其代码不包含在 BiliNext 中。详见 [官方播放器说明](docs/OFFICIAL-CLIENT-PLAYER.md)。

更完整的功能覆盖与待办见 [功能清单](docs/PILIPLUS-MIGRATION.md)，已完成的检查与实测范围见 [当前验证状态](docs/VALIDATION.md)。

## 开发与贡献

后续开发与发布以本仓库的 Swift 应用为准。欢迎通过 [Issues](https://github.com/nickxudotme/BiliNext/issues) 反馈问题或提出建议；报告播放问题时，请提供系统版本、应用版本、视频 BV 号及复现步骤，避免提交 Cookie、登录凭据或其他账号敏感信息。

- [本地构建与测试](docs/DEVELOPMENT.md)
- [贡献约定](CONTRIBUTING.md)
- [发布流程](docs/RELEASE.md)
- [libmpv 播放内核](docs/MPV-PLAYBACK.md)
- [渲染与性能](docs/RENDERING-PERFORMANCE.md)

接口与功能实现参考了 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)、[bilibili-api](https://github.com/Nemo2011/bilibili-api) 和 BBHouse 等项目；研究记录见 [参考项目清单](docs/REFERENCE-STUDY-2026-10.md)。

## 许可证

BiliNext 源码采用 [GNU GPL v3](LICENSE)。第三方组件及其许可证说明见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
