# 本地开发

## 构建应用

本地开发需要 Xcode、`brew install mpv pkgconf` 和持久的代码签名证书。运行库打包与 macOS 26 兼容要求见 [mpv 构建说明](MPV-PLAYBACK.md)。在本机运行 `security find-identity -v -p codesigning`，将选定证书的 SHA-1 写入项目根目录 `.signing-identity`，或设置 `BILINEXT_SIGNING_IDENTITY`。该本机配置已加入 `.gitignore`。

```sh
bash scripts/build-app.sh
open build/BiliNext.app
swift test
```

默认生成签名 Debug 开发包，沿用下述本机开发会话后端，日常重编译不读取钥匙串。正式包需显式运行 `BILINEXT_BUILD_CONFIGURATION=release bash scripts/build-app.sh`；Release 继续只使用钥匙串，不回退到开发文件。

保持持久证书签名，但不要认为本地自签证书已经解决钥匙串提示：实际排查发现，旧文件型钥匙串还有基于 `cdhash` 的 partition 限制，稳定 designated requirement 并不足够。正式分发仍需处理 Apple 开发／Developer ID 签名与公证。

开发期间，`DEBUG` 构建将会话存到 `~/Library/Application Support/BiliNext/Development/login-session.json`。目录权限为 0700，文件为 0600，未加密且不在仓库中；这是用户明确选择的开发便利性取舍。首次迁移只静默尝试读取旧钥匙串，拒绝时重新扫码一次。已有开发会话文件时不访问钥匙串；退出写入空记录，防止下次启动重新导入旧登录。旧钥匙串条目保留给正式版。

本地会话后端通过 `#if DEBUG` 限定，Release 构建只提供钥匙串后端。开发文件仍是凭据文件，不应复制到仓库或发给他人。

直接 `swift run` 或 Xcode 的未签名产物具有不同身份，不能用它们代替已签名 App 验证钥匙串持久授权。


## 检查与集成测试

开发约定见 [CONTRIBUTING.md](../CONTRIBUTING.md)，当前验证范围见 [VALIDATION.md](VALIDATION.md)。

默认 `swift test` 不访问真实账号。公开网络测试使用 `BILINEXT_LIVE_TEST=1 swift test`；账号只读测试使用 `BILINEXT_AUTH_TEST=1 swift test`。真实 OpenGL 渲染测试使用 `BILINEXT_MPV_TEST=1`，需要可用的图形上下文。Debug 账号测试复用开发会话文件，不访问钥匙串。
