# Homebrew 发布

分发目标为 SwiftUI + AppKit 原生应用；源码仓库为公开的 `nickxudotme/BiliNext`。沿用 ScreenOff 的 GitHub Release → Homebrew tap 自动更新方式。

## 构建产物

```sh
brew install mpv pkgconf
BILINEXT_VERSION=0.1.0 BILINEXT_BUILD_NUMBER=1 bash scripts/build-release.sh
```

生成 `build/BiliNext.app` 和 `dist/BiliNext-0.1.0-arm64.zip`，并打印 SHA-256。版本号仅接受三段数字；build number 为整数。发布脚本强制 Release 配置与 ad-hoc 签名，不读取本机私钥，也不改变本地开发默认的签名与运行库打包方式。图标原样复制自 `Resources/BiliNext.icns`。

首期只支持 Apple Silicon，最低 macOS 26。CI 使用 `macos-26` 构建；本机在更新系统上构建的结果不能替代在 macOS 26 上的实际验证。

发布版直接链接 Homebrew 的 mpv opt 路径，cask 声明 `depends_on formula: "mpv"`；ZIP 不含 mpv 或其依赖库，不能脱离 Homebrew 当作独立安装包使用。Homebrew 负责运行库安装、许可证文件和后续升级。依赖 ABI 或最低系统版本变化时仍需重新验证；本项目和依赖的许可证及源码提供要求也仍需遵守。

## 自动发布

推送 `v<version>` tag，或在 Actions 手动运行 Release 并填写版本号。正式发版前应提交并推送本次源码与发布配置；不要在工作区有未提交改动时打 tag。

工作流依次执行离线测试、格式检查、Release 打包、图标与版本校验、严格签名验证，然后上传 GitHub Release，并更新 `nickxudotme/homebrew-tap/Casks/bilinext.rb` 的版本和校验和。手动发布遇到已有 tag 时要求它与构建的提交一致，避免用同一个 tag 发布不同源码。

BiliNext 仓库的 `TAP_DEPLOY_KEY` Secret 保存对 tap 有写权限的专用 deploy key；与 ScreenOff 分开管理。缺失时 Release 仍可成功，但工作流会警告需要手动更新 tap。`scripts/update-homebrew.py <version> <sha256> <tap目录>` 从 `packaging/homebrew/bilinext.rb.in` 渲染 cask，拒绝格式错误的版本号或 SHA-256。

## 安装与升级

```sh
brew install --cask nickxudotme/tap/bilinext
brew upgrade --cask nickxudotme/tap/bilinext
```

cask 通过 `caveats` 显示应用尚未公证的说明，以及实际安装目录对应的完整 `sudo /usr/bin/xattr -dr com.apple.quarantine "<appdir>/BiliNext.app"` 命令；安装、重装和升级均不会自动执行该命令。如果 macOS 阻止打开，用户查看说明后在终端手动执行，需要时直接输入 sudo 密码，输入不回显。提示中的路径支持自定义 `--appdir`。

此操作只删除 BiliNext 的隔离标记，不改变钥匙串授权。Release 继续使用钥匙串保存登录状态；没有稳定的 Developer ID 身份时，升级可能需要重新授权。用户接受这一升级体验，暂不更换登录存储后端。开发版原有文件存储限定在 DEBUG，不进入发行包。

## 发版检查

- 离线测试、格式检查、Release 编译与严格签名检查。
- 解包 ZIP 后核对版本、图标和 Homebrew mpv 链接路径。
- 安装与升级时确认显示实际安装路径和完整手动命令，且安装过程不自动移除隔离标记；需要解除隔离时，手动执行后检查 BiliNext 的 quarantine 属性。
- 从实际安装位置启动，验证登录、视频播放与升级后的钥匙串行为。
- 项目采用 GPL-3.0-only；App 内附 LICENSE 和第三方依赖说明。正式 Release 对应的 tag 保留源码与构建脚本。

尚未发布时不要把模板当作已可安装的 cask，也不要用 ScreenOff 的安装结果替代 BiliNext 的实测。

## CI 测试环境

macOS 托管 runner 没有应用所需的加速 OpenGL 上下文；真实图层与渲染队列回归测试使用 `BILINEXT_MPV_TEST=1` 在具备图形上下文的本机运行。CI 默认测试使用 `swift test --no-parallel`，避免并发的主线程测试相互延迟，影响退出等待等时限断言；不扩大断言的时间阈值。

## 首次发布状态（2026-10-19）

0.1.2 和 0.1.3 已由 macOS 26 CI 正式发布，tap 已自动更新到 0.1.3。二者采用相同源码，用于真实的旧版安装与新版升级验证。早期 `v0.1.0`、`v0.1.1` 标签仅对应失败的 CI，没有发布安装包。

正式 ZIP 的下载与解包校验，以及本机 0.1.2 安装 → 0.1.3 升级均已通过；版本、签名、原始图标、许可证、mpv 链接和隔离标记检查通过，安装后的应用进程已启动。钥匙串跨升级授权体验、登录持久性和真实播放仍待界面确认。当前状态详见 [VALIDATION.md](VALIDATION.md)。

上述安装记录对应首次发布时的自动解除隔离流程。2026-10-20 起仓库中的 cask 模板改为仅提示手动命令；历史验收不能代替新流程的实际安装验收。
