# Cookie 刷新实现前研究（2026-10-15）

本轮使用 `reverse-engineer-anything`／REA 只读研究已安装的官方客户端 **1.19.0（1.19.0.5063）**，没有启动它、读取用户凭据或发送刷新请求。ASAR SHA-256：`3c806214c008bf23d2b635f800cec0ab28087d85ced4f8122dd849c8f4e5cf23`。以下为静态观察，不能视为当前服务端或真实账号验收。

## 官方桌面流程

1. `mainWindowReady$` 后，已登录且有 refresh token 才检查 `cookie/info`，附当前 `bili_jct`；只有返回 `refresh=true` 才继续。
2. 生成 AES-GCM challenge，请求 `/correspond/2/<challenge>`，从 HTML 的 `2-value` 解密取得 refresh CSRF。
3. 使用旧 token、refresh CSRF 和当前 CSRF 请求 `cookie/refresh`。
4. 保存新的 refresh token，合并 Set-Cookie 并保存认证 Cookie。
5. 使用更新后的 Cookie／CSRF，携带旧 token 请求 `confirm/refresh`。

官方 token 单独加密存入 `secureStore`；这条链没有使用 Keychain 的证据。登录 token IPC 接收器接受 `token` 或 `refresh_token`，限定登录窗口。确认请求在该静态视图中未 await；错误、丢响应及重启恢复策略尚未证实。300 秒 Cookie 缓存清理不是已确认的刷新周期。

## 来源对照与适用边界

本地参考仓库本轮均无未提交改动；只研究接口和状态流，未复制实现。

| 来源与固定版本 | 本轮观察 | 对 BiliNext 的适用范围 |
| --- | --- | --- |
| 官方桌面 1.19.0.5063，ASAR 摘要见上文 | `/correspond/2/` AES-GCM；token 与 Cookie 分开保存 | 参考触发、顺序和持久化；不能与 Web `/1` challenge 混用 |
| [bilibili-api 本地 fork](https://github.com/nooblong/bilibili-api/tree/4789508a93f3a39b7d3c896273309db892a9cc8b)，`4789508a93f3a39b7d3c896273309db892a9cc8b` | `utils/network.py` 的 Web `/1` 刷新与 `data/api/credential.json` | 独立重实现 Web 协议；不是官方桌面 `/2` 的源码证明 |
| [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2515ecfc8743e06c137f852399cdec1df036f3c2)，`2515ecfc8743e06c137f852399cdec1df036f3c2` | 当前扫码走 TV/HD；账号保存 Cookie、access token、refresh token | 参考数据分层，不能把 TV/App token 当成 Web Cookie 刷新 token |
| 社区 bilibili-API-collect 贡献者归档，`cfc5fddcc8a94b74d91970bb5b4eaeb349addc47` | [Web Cookie 刷新](https://raw.githubusercontent.com/pskdje/bilibili-API-collect/cfc5fddcc8a94b74d91970bb5b4eaeb349addc47/docs/login/cookie_refresh.md)、[Web／TV 二维码](https://raw.githubusercontent.com/pskdje/bilibili-API-collect/cfc5fddcc8a94b74d91970bb5b4eaeb349addc47/docs/login/login_action/QR.md) | 对照参数与 token 来源；归档文档不是当前服务端保证 |

PiliPlus 的 `refreshQRCode → getHDcode → codePoll` 使用签名的 TV `auth_code/poll`；密码／短信分支也使用 App 认证。`setAccount` 将返回的两类 token 与 Cookie 存入 `LoginAccount`，再由 Hive adapter 持久化；手动 Cookie 登录允许两类 token 均为空。定位：[登录请求](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/2515ecfc8743e06c137f852399cdec1df036f3c2/lib/http/login.dart#L35)、[扫码入口](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/2515ecfc8743e06c137f852399cdec1df036f3c2/lib/pages/login/controller.dart#L73)、[账号字段](https://github.com/bggRGjQaUbCoE/PiliPlus/blob/2515ecfc8743e06c137f852399cdec1df036f3c2/lib/utils/accounts/account.dart#L42)。本提交 `lib` 的登录、HTTP 和账号存储路径未找到 Web QR 或上述四步 Web 刷新链；这是限定范围的源码观察，不是否定其他版本或运行时行为。`getWebKey` 的名称不能证明它走 Web QR。

2026-10-15 核对：[社区原主仓](https://github.com/SocialSisterYi/bilibili-API-collect)仍可访问，但已归档并删除原文档，仅保留关停说明；[原刷新文档站点](https://socialsisteryi.github.io/bilibili-API-collect/docs/login/cookie_refresh.html)返回 404。本研究采用[贡献者归档说明](https://github.com/pskdje/bilibili-API-collect)指定的 `master`，经 `git ls-remote` 固定到上表提交，两个固定版本原文均返回 200；不将镜像称作仍在维护的原主仓，也不将社区文档称作 B 站官方文档。

## BiliNext 的实现契约

- 现有扫码成功分支只保存 Cookie，缺少 `refresh_token`；凭据是旧 `[CookieRecord]` 数组。须先兼容迁移至有版本的 Cookie／token 格式，保留 Release Keychain 和 DEBUG developmentFile 的边界，标明 token 的 Web 来源。社区 Web QR 文档也将 `refresh_token` 列为成功响应字段；旧会话没有 token 时跳过刷新，下一次成功扫码再保存，不能从 Cookie 臆造 token，也不能拿 PiliPlus 的 TV/App 同名字段替代。
- 当前使用 Web QR 登录，应独立实现 Web `/correspond/1/` 契约：RSA-OAEP-SHA256 加密 `refresh_<毫秒时间>` 并编码为小写 hex，解析 `1-name`；社区文档给出 `cookie/info` 的毫秒 `timestamp`，可优先作为 challenge 时间。刷新 POST 使用旧 Cookie／CSRF、refresh CSRF、旧 token 和 `source=main_web`。不能混用官方桌面 `/2` 的 AES challenge。
- 同一账号代次内串行维护，登录／退出／换账号作废旧任务；新 Cookie 与 token 作为候选验证、原子持久化后发布。旧 token 的待确认记录应跨重启保留，确认成功后清除。
- 两个 POST 不进入通用重试。故障注入须覆盖服务端已刷新但客户端丢响应、确认结果未知、存储失败和账号切换。刷新失败不能清空有效登录或变成播放错误。
- 社区文档称 confirm 会使旧 token 对应的 Cookie 失效，并列出刷新错误 `-101`、`-111`、`86095`；必须区分未登录、CSRF 错误和 token／Cookie 不匹配，不能把失败当成轮换成功。该文档另列跨域 SSO；本项目是否需要额外站点登录仍待单独验证。
- 先完成离线状态机和协议测试，再单独验收真实账号刷新；本轮仅完成研究，未实现或验收刷新。

## 静态证据与限制

历史认证主进程明文按 0 起始、半开字节偏移 P 标记：启动订阅 `P[522080,525821)`；接口封装 `P[465488,467313)`；完整顺序 `P[566984,571865)`；token 读取／加密保存 `P[416561,418110)`；Cookie 保存及广播 `P[407110,409245)`；登录 token IPC `P[1475333,1476101)`。

- 主进程视图 Evidence：`ev_27753501cee6c2733554b07f64051bfe693492bca55c304360f22995a2d16e30`，语义图达到节点上限，覆盖 partial。
- 17 方法受限投影 Evidence：`ev_df7f2c53536fae30dccbcc19fa6f4642856e129d0c992a6cb3e4326970b83f6d`。仅为不执行的静态分析载体，不能声称整程序等价。
- 旧 token 同时流入刷新和确认参数的 trace：`ev_7d6d6214a90c42b86a7f1ff63d121e8f05aaffd71f4220cad915d131a1bf64a1`，状态 found；未读取实际 token。

社区文档补足了 Web QR token 字段和声明的失效语义；当前服务器 `/1`、`/2` 的实际响应、失败后的轮换状态仍未验证，也未完整追踪官方桌面登录页面如何取得 token。完整原始导出仅保留在本机 `/tmp/bilinext-cookie-rea-20261015-evidence.json`，不将官方源码或原始导出提交到仓库。
