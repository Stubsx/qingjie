# 轻截应用身份约定

- 应用固定身份以 `Resources/AppIdentity.json` 为准。Bundle ID 保持 `com.local.qingjie`，日常启动路径保持 `/Applications/轻截.app`。
- 所有可运行构建必须通过 `./scripts/build.sh`。不得使用 ad-hoc 签名（`codesign --sign -`）、只校验 Bundle ID 的宽松签名规则或每次生成新证书。
- 每次 `./scripts/build.sh` 构建成功后自动替换 `/Applications/轻截.app`：脚本先让正在运行的轻截优雅退出，按 install 的完整签名校验整体替换，最后自动重启应用。仅构建 dist 不安装需显式 `./scripts/build.sh --no-install`（如打包发布前）。
- 本机签名证书已固定指纹，私钥保存在用户的 `~/Library/Application Support/QingJie/Signing` 专用钥匙串中。只能让签名脚本使用凭据，不要直接查看或输出密码及私钥，不要提交、复制到 dist 或打包。证书或私钥丢失时先恢复备份，不得自动换身份。
- 更新安装使用 `./scripts/install.sh`；先退出正在运行的轻截，再完整替换经过签名验证的应用。用原生 UI 工具退出/打开应用；不要同时运行 dist 和 Applications 两个副本。
- 应用内自动更新与 install.sh 同一身份标准：下载包必须 sha256 匹配更新源、`codesign --verify --deep --strict -R` 通过固定证书指纹规则、Designated Requirement 与固定身份一致，才允许整体替换 `/Applications/轻截.app`；替换由退出后的独立脚本完成并带回滚。发布更新源使用 `python3 scripts/app_identity.py feed`（或 `publish` 直写 gist），gist 地址与 `Sources/QingJie/UpdateSettings.swift` 的 endpoint 保持一致。
- 权限与身份验证使用 `python3 scripts/app_identity.py verify /Applications/轻截.app` 和 `python3 scripts/verify_identity.py`。不得编辑 TCC 数据库、重置其他应用权限或自动打开系统隐私权限。
- 本机证书不是 Apple Developer ID。将来正式对外发布需明确迁移到 Developer ID Application 与固定团队；必须说明这次签名根变更可能要求用户重新授权，不得声称可无条件继承本机证书权限。

# 界面文案规范

- 设置项的说明文案（副标题）只写一句话、一个逗号以内，描述用户能感受到的行为，如「登录 Mac 后自动运行，驻留菜单栏。」「关闭后仅驻留菜单栏，截图与快捷键不受影响。」。
- 不写技术实现与内部细节：不出现校验、签名身份、sha256、匿名请求、替换流程、自动重启机制等实现层表述；安全保障由 AGENTS.md 的身份约定与签名流程保证，无需在界面上解释。
- 版本号、检查结果等动态状态由单独的状态行展示（如「已是最新版本 0.6.18 · 上次检查 17:53」），不要混入说明文案。
