# Developer ID 签名与分发

固定团队：H7FC4T962X。Developer ID Application 证书已安装在登录钥匙串；证书与私钥需要由用户安全备份，不能提交到 Git 或放入发布包。原本机证书保留，不用于新版本签名。

## Apple 公证凭据（已配置）

使用 App Store Connect 团队 API 密钥“Mac App 公证”，角色为开发者。Key ID：MFT7CFSK6B；Issuer ID：5d9163e2-6220-43a9-b82e-da8f670184df。

公证凭据已通过 Apple 验证并保存在本机钥匙串 profile `qingjie-notary`。API 私钥存放在 `~/Library/Application Support/QingJie/Notary/AuthKey_MFT7CFSK6B.p8`（目录 700、文件 600），未放入项目或发布包。请由用户安全备份，Apple 只允许下载一次。不要输出私钥或将其上传到 Git。

同一组凭据可用于该团队的多个 App；每份新构建仍需单独提交公证。若以后需要在本机恢复钥匙串配置，可运行：

```sh
xcrun notarytool store-credentials qingjie-notary --key "$HOME/Library/Application Support/QingJie/Notary/AuthKey_MFT7CFSK6B.p8" --key-id MFT7CFSK6B --issuer 5d9163e2-6220-43a9-b82e-da8f670184df
```

## 构建与分发

```sh
./scripts/build.sh --no-install
python3 scripts/app_identity.py notarize
```

notarize 提交 ZIP 给 Apple、等待 Accepted、给 app 附加票据、验证 Gatekeeper，并重新生成含票据的 ZIP。成品为 dist/qingjie-macOS-arm64.zip。feed/publish 会拒绝未通过公证的 Developer ID 包。随后沿用现有 feed/publish 更新源流程；公开发布前应递增版本/build。

## 旧本机签名的首次迁移

退出正在运行的轻截后执行：

```sh
./scripts/install.sh --migrate-local
python3 scripts/app_identity.py verify /Applications/轻截.app
python3 scripts/verify_identity.py
```

迁移会验证并备份原固定本机签名应用，备份位置是 ~/Library/Application Support/QingJie/Signing/migration-backup/轻截.app。以后安装继续使用普通 install.sh。日常只启动 /Applications/轻截.app。

签名根发生变化，macOS 可能要求重新授予截图、麦克风等权限；不会修改 TCC 或其他应用权限。旧版本自动更新仅信任旧证书，不能自动接受新签名；已有用户需手动安装此次迁移版本。

## 第二台开发机（已验证）

第二台 Mac 已迁移同一证书与公证 API 密钥。远端登录钥匙串不支持 SSH 非交互导入，因此使用 `~/Library/Application Support/QingJie/DeveloperSigning/developer-id.keychain-db` 独立钥匙串，私有凭据仅由同目录的 `developer-tools.py` 读取。命令执行后会锁定钥匙串。远端实际签名及 Apple 公证身份验证已通过。

```sh
python3 "$HOME/Library/Application Support/QingJie/DeveloperSigning/developer-tools.py" build /path/to/project --no-install
python3 "$HOME/Library/Application Support/QingJie/DeveloperSigning/developer-tools.py" notarize /path/to/project
```

使用前先同步本次项目修改，并将项目路径替换为远端真实路径；本次仅迁移开发凭据，未同步或覆盖远端项目。包装脚本通过 `QINGJIE_NOTARY_KEYCHAIN` 指定远端公证钥匙串。
