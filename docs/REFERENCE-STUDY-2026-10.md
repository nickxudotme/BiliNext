# 参考项目研究与待办（2026-10-15）

来源：bilibili-api（Python，GPL-3.0）、PiliPlus（Flutter，GPL-3.0）、官方桌面客户端（本轮 Cookie 静态样本 1.19.0.5063，历史研究保留各自版本）、社区 bilibili-API-collect 归档文档。本轮参考仓库位于仓库外 `../bilibili-api`、`../PiliPlus`；固定提交与社区原仓／归档状态见 [Cookie 研究来源对照](OFFICIAL-COOKIE-REFRESH.md#来源对照与适用边界)。只学习接口与做法，未复制代码。

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
| 1 | ~~自动连播与播完后模式~~（已完成） | PiliPlus | S–M | |
| 2 | ~~看点章节~~（已完成 `35c3408`） | 三者 | S | |
| 3 | ~~进度条缩略图~~（已完成） | bilibili-api | S–M | |
| 4 | Cookie 刷新：`cookie/info` → correspond → `cookie/refresh` → `confirm/refresh`，并保存扫码返回的 `refresh_token` | 官方、bilibili-api、PiliPlus、社区归档 | M | 已完成[来源对照研究](OFFICIAL-COOKIE-REFRESH.md)；拟按 Web `/1` 实现，不能复用 TV/App token；先兼容旧凭据格式，无 token 时跳过；尚未实现 |
| 5 | ~~编码偏好与无损／杜比音轨~~（已完成）；响度均衡 `voice_balance` 未做 | PiliPlus、bilibili-api | S | |
| 6 | ~~快捷键补全~~（已完成，设置中列出） | 官方、PiliPlus | S | |
| 7 | 设置扩充（部分完成）：默认清晰度、默认倍速、长按倍速、快进步长、自动连播已接入；自定倍速列表、字幕偏好（跳过 AI 字幕）、暂停记录历史待做 | PiliPlus | M | 新偏好覆盖原生 mpv；官方核心首次连接继承倍速仍待补 |
| 8 | 弹幕：合并重复、按权重屏蔽等级、正则／UID 屏蔽并与账号规则同步 | PiliPlus | M | |
| 9 | 跳过片段：SponsorBlock 与番剧片头片尾（`clip_info`），按类别自动／提示 | PiliPlus | M | 外部服务需用户同意 |
| 10 | AI 总结面板：`/x/web-interface/view/conclusion/get`，带时间点跳转 | PiliPlus、bilibili-api | S–M | 签名接口，登录后可用 |
| 11 | 评论互动（部分完成）：点赞／取消赞已接入；评论回复、发送／点赞弹幕待做 | bilibili-api | M | 仅用户点击触发写操作；真实账号写入尚未验收 |
| 12 | 空间页补全：空间动态、代表作、公告、关系状态（回关／互关）、合集排序 | bilibili-api、PiliPlus | M | 动态为签名接口 |
| 13 | ~~WBI 遇 -403 刷新密钥并重试一次；签名请求默认带 `web_location`~~（已完成） | bilibili-api | S | 仅签名 GET 的 API -403 重试一次，保留显式参数，不重放账号写操作；并发及取消有离线请求测试 |
| 14 | ~~在线人数 `/x/player/online/total`~~（已完成） | bilibili-api | S | 简介展示全部客户端 `total`；只在前台当前简介按 30 秒刷新，切页取消 |
| 15 | 收藏管理（部分完成）：收藏夹新建／重命名／删除已接入；资源移动复制、稍后再看清空待做 | bilibili-api | S–M | 默认新建私密；默认收藏夹不可改名／删除；真实账号写入尚未验收 |
| 16 | 画中画（系统 PiP） | PiliPlus | M | 与小窗互补 |
| 17 | 自管 HTTP 层喂给 mpv：首字节超时换镜像、一次取头与索引、连接复用 | 官方客户端 | L | 弱网收益最大，单独评估 |
| 18 | ~~评论超长回复链性能与详情页请求取消~~（已完成） | 本仓库回归 | M | 平面索引及迭代遍历，5 万层压力检查通过；离开/覆盖/换视频取消，恢复同页。超大已加载列表的实际滚动性能仍需跟踪 |
