# 应用身份与权限连续性

轻截从 0.5.3 起使用固定本机代码签名，身份合同见 `Resources/AppIdentity.json`。

| 项目 | 固定值 |
| --- | --- |
| 应用名称 | 轻截 |
| Bundle ID | `com.local.qingjie` |
| 可执行文件名 | `QingJie` |
| 日常安装与启动位置 | `/Applications/轻截.app` |
| 本机签名证书 | `QingJie Local Code Signing` |
| 证书有效期 | 2026-09-13 至 2036-09-10 |
| 权限身份校验 | Bundle ID + 固定证书指纹；不包含每版变化的代码哈希 |

原来的 ad-hoc 签名采用 `designated => cdhash …`，重新编译导致哈希变化，旧权限记录可能无法匹配。新构建用固定证书签名，并嵌入校验该证书的 Designated Requirement。代码仍做完整签名校验，签名被破坏或只有相同名称的应用不会通过校验。

从旧临时签名迁移到新身份后，macOS 可能要求再授权一次。请在系统设置中授权 `/Applications/轻截.app`，后续更新保持同证书、同 Bundle ID、同安装位置。身份回归测试能证明新版符合旧版代码身份规则；实际权限延续仍由 macOS 管理，不能保证免除系统定期提醒或用户撤销权限后的授权。

## 常规开发和更新

```bash
./scripts/build.sh
# 构建签名成功后自动替换 /Applications/轻截.app：
# 正在运行的轻截会先优雅退出，替换完成后自动重启。
./scripts/build.sh --no-install
# 仅构建 dist 成品（如打包发布前）；手动安装用 install.sh。
./scripts/install.sh
# 手动安装更新；会检查应用是否已退出。
python3 scripts/app_identity.py package
# 发布应用内更新：上传压缩包后生成并发布更新源
python3 scripts/app_identity.py feed --package-url <压缩包 https 地址>
# 或用 gh CLI 直接上传 GitHub Release 并自动推导下载地址
python3 scripts/app_identity.py publish --github-repo <owner/repo>   # gh 登录含 gist 权限，或 QINGJIE_GIST_TOKEN
```

构建时先生成完整临时应用，签名和身份校验成功后才替换 dist 成品。构建还会把证书指纹写入 Info.plist（`QingJieCertificateSHA1`），应用内更新用它校验下载包身份。构建成功后自动替换当前安装：先向正在运行的轻截发送退出事件（首次可能需要允许终端的自动化控制授权），再按 install 流程整体替换并重启。安装时同样先校验新旧身份，应用未退出、证书丢失、身份不匹配或签名损坏都会停止，不会回退临时签名或覆盖身份不同的已安装应用。打包只包含签名后的 `.app`，并核对压缩包中的二进制和 Info.plist。

每次修改发布内容都应递增版本/build，并使用新的 Release 标签。上传的文件名包含版本、build 和 SHA-256 前缀；同一 Release 已有不同安装包时脚本会停止，禁止覆盖旧文件。重复发布完全相同的包会复用既有资产。写入更新源前还会验证压缩包对应当前构建，并核对 GitHub 返回的大小与 SHA-256；手动指定 `--package-url` 时也必须使用不会被覆盖的下载地址。

客户端在点击「下载并安装」时重新获取更新源，避免使用此前检查时保留的旧校验值。版本检查请求绕过缓存，下载先检查 HTTP 状态，再核对文件大小、SHA-256 与固定签名。更新信息无法刷新或任何校验失败都会停止安装。

运行时检测相同 Bundle ID 的其他实例，重复启动会转到已有实例，避免多份应用争抢全局快捷键。快捷键偏好和历史目录沿用旧版。

## 本机签名资料

私钥位于 `~/Library/Application Support/QingJie/Signing/qingjie-signing.keychain-db`。同目录保存钥匙串密码文件和公开证书，目录仅当前用户可访问。临时生成的 PEM 私钥与 PKCS#12 文件会清理，不进入项目或安装包。

签名脚本按固定指纹选择证书，只在签名期间解锁专用钥匙串、临时加入搜索列表，结束后锁定并恢复搜索列表。没有设置系统信任根，也不编辑 TCC 或自动开启隐私权限。

**请将整个 Signing 目录纳入私人的安全备份。** 不能只保存公开证书，不能将此目录放入 Git、dist 或分享包。换开发机器时恢复同一目录，才能继续使用原签名。脚本再次执行 `init-local` 会保留已有身份；资料缺失或状态不完整时会停止，不会自动生成新证书。

```bash
python3 scripts/app_identity.py status
python3 scripts/app_identity.py verify /Applications/轻截.app
python3 scripts/verify_identity.py
```

验证脚本创建两个不同的临时二进制，检查代码哈希不同、身份规则相同、新版通过旧版身份校验，并验证未签名、遭篡改和变更 Bundle ID 的应用被拒绝。测试应用不会启动或申请权限。

## 将来对外发布

本机证书不等同于 Apple Developer ID，不具备苹果公证资格。对外正式发布时需要配置 Developer ID Application 证书和固定 Apple 团队，并完成公证。当前脚本会拒绝未知签名配置；迁移必须明确执行，不能自动选择钥匙串中“任意可用证书”。

Bundle ID、应用名称、安装位置、偏好和历史目录继续保持不变。但本机证书切换到 Apple 签名链属于身份根迁移，旧权限可能需要重新授权一次；不能承诺直接继承。迁移完成后，正式开发测试和分发构建应沿用同一发布身份规则，Apple 证书续期采用固定团队身份，避免再次按具体证书或代码哈希绑定。
