# 开发约定

- 使用 Swift；应用界面位于 `Sources/BiliNext`，接口和领域模型位于 `Sources/BiliNextCore`。
- Swift 文件采用四空格缩进、100 字符目标行宽；复杂条件和多条操作展开写。文件名与主要类型对应。
- 格式化：`xcrun swift-format format --in-place --recursive --configuration .swift-format Package.swift Sources Tests`。
- 格式检查：`bash scripts/check-format.sh`。使用当前 Xcode 自带工具，不额外安装格式工具。
- 每次提交只处理一个目的；纯格式调整与行为变更分开。提交前运行格式检查和 `swift test`，涉及条件编译时同时运行 `swift build -c release`。
- 修改窗口、播放器或导航后，使用 `bash scripts/build-app.sh` 的签名 App 验证实际交互；检查标签切换、关闭撤销、重启恢复、暂停与字幕跳转。记录未验证项。
- 默认测试不访问真实账号；账号写操作必须由用户操作或明确授权触发。
- 不提交 `.build`、`build`、`.signing-identity`、凭据和本机会话数据。参考项目原位置保留，源码来源和许可证审查要求继续有效。
