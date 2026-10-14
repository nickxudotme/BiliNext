# 参考项目研究与待办（2026-10-15）

来源：bilibili-api（Python，GPL-3.0）、PiliPlus（Flutter，GPL-3.0）、官方桌面客户端 1.17.9（本机 `app.asar`）。只学习接口与做法，未复制代码。参考项目克隆在仓库外 `~/my-studio/references/`。

## 已经落地

| 来源 | 做法 | 提交 |
| --- | --- | --- |
| PiliPlus | 播放地址改写到固定官方镜像，PCDN 退为回退 | `5376a6c`、`b13f786` |
| 官方客户端 | 起步预读小、随播放时长增大 | `dcdf53e` |
| 官方客户端（改进） | playurl 与详情并行；悬停预取（设置项，默认关） | `d5f1437` |
| 本仓库排查 | 首帧即播、DNS 常驻、启动埋点 | `5376a6c`、`b13f786` |
| 通用 | 系统「正在播放」与媒体键 | `128875e` |

## 不做（或需另行决定）

- 伪造的 `dm_img_*` 指纹、gaia `ExClimbWuzhi` 伪造载荷、冒充 Android App 签名、`from_client=PC_APP`：违反「不绕过风控」。影响见 [PiliPlus 迁移 · 未登录风控](PILIPLUS-MIGRATION.md)。
- PiliPlus 的 TV／HD 扫码换 `access_key`、gRPC App 接口：同属冒充客户端，暂不做。
- 官方的 PCDN SDK、`v_voucher` 验证码流程：客户端专有，无法也不需要移植。

## 待办（按日常观看收益排序）

| # | 项目 | 来源 | 工作量 | 备注 |
| --- | --- | --- | --- | --- |
| 1 | 自动连播：分 P → 合集 → 相关推荐，播放顺序模式（列表／单集循环／播完暂停） | PiliPlus | S–M | 追番、看合集的基本流程 |
| 2 | ~~看点章节~~（已完成 `35c3408`） | 三者 | S | |
| 3 | 进度条缩略图：`/x/player/videoshot` 雪碧图，拖动或悬停预览画面 | bilibili-api | S–M | 公开接口 |
| 4 | Cookie 刷新：`cookie/info` → correspond → `cookie/refresh` → `confirm/refresh`，并保存扫码返回的 `refresh_token` | bilibili-api | M | Release 钥匙串登录可能静默过期 |
| 5 | 编码偏好与音质：用户排序 AV1／HEVC／AVC，Hi-Res（flac）、杜比音轨，响度均衡 `voice_balance` | PiliPlus、bilibili-api | S | 当前写死 AV1 > HEVC > AVC |
| 6 | ~~快捷键补全~~（已完成，设置中列出） | 官方、PiliPlus | S | |
| 7 | 设置扩充：默认清晰度、倍速列表、长按倍速、快进步长、字幕偏好（跳过 AI 字幕）、暂停记录历史、自动连播 | PiliPlus | M | 设置窗口已有框架 |
| 8 | 弹幕：合并重复、按权重屏蔽等级、正则／UID 屏蔽并与账号规则同步 | PiliPlus | M | |
| 9 | 跳过片段：SponsorBlock 与番剧片头片尾（`clip_info`），按类别自动／提示 | PiliPlus | M | 外部服务需用户同意 |
| 10 | AI 总结面板：`/x/web-interface/view/conclusion/get`，带时间点跳转 | PiliPlus、bilibili-api | S–M | 签名接口，登录后可用 |
| 11 | 评论点赞与回复、发送／点赞弹幕（仅用户点击触发） | bilibili-api | M | 写操作 |
| 12 | 空间页补全：空间动态、代表作、公告、关系状态（回关／互关）、合集排序 | bilibili-api、PiliPlus | M | 动态为签名接口 |
| 13 | WBI 遇 -403 重算密钥并重试一次；签名请求默认带 `web_location` | bilibili-api | S | 减少偶发失败 |
| 14 | 在线人数 `/x/player/online/total` | bilibili-api | S | |
| 15 | 收藏夹增删改、移动复制，稍后再看清空 | bilibili-api | S–M | |
| 16 | 画中画（系统 PiP） | PiliPlus | M | 与小窗互补 |
| 17 | 自管 HTTP 层喂给 mpv：首字节超时换镜像、一次取头与索引、连接复用 | 官方客户端 | L | 弱网收益最大，单独评估 |
