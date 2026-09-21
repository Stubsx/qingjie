#!/usr/bin/env python3
"""Keep the app's code requirement stable; never fall back to ad-hoc signing."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "Resources/AppIdentity.json"
SIGNING = Path.home() / "Library/Application Support/QingJie/Signing"
KEYCHAIN = SIGNING / "qingjie-signing.keychain-db"
PASSWORD = SIGNING / "keychain-password"
OPENSSL = "/usr/bin/openssl"
# 与 Sources/QingJie/UpdateSettings.swift 中的 endpoint 指向同一 gist。
FEED_GIST = "6b32edfa0f8eb36dfc5ee9ed2de582be"
FEED_FILE = "latest.json"
SECRETS = []


def run(args, capture=True):
    result = subprocess.run([str(arg) for arg in args], stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        detail = result.stdout or "请查看上方输出。"
        for secret in SECRETS:
            detail = detail.replace(secret, "[redacted]")
        raise RuntimeError(f"{Path(args[0]).name} 失败：{detail.strip()}")
    return (result.stdout or "").strip()


def config():
    value = json.loads(CONFIG.read_text())
    if value["signingProfile"] != "local":
        raise RuntimeError("当前脚本只支持已固定的本机签名；正式发布需明确配置 Developer ID 身份。")
    if not re.fullmatch(r"[A-Za-z0-9.-]+", value["bundleIdentifier"]):
        raise RuntimeError("无效的 Bundle ID。")
    return value


def fingerprint(value):
    sha1 = value.get("certificateSHA1") or ""
    if not re.fullmatch(r"[A-F0-9]{40}", sha1):
        raise RuntimeError("尚未固定签名证书。首次运行 python3 scripts/app_identity.py init-local；不可使用临时签名替代。")
    return sha1


def requirement(value):
    return f'identifier "{value["bundleIdentifier"]}" and certificate leaf = H"{fingerprint(value)}"'


def check_bundle(app, value):
    if app.is_symlink():
        raise RuntimeError("应用目录不能是符号链接。")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": value["bundleIdentifier"], "CFBundleExecutable": value["executable"],
                "CFBundleName": value["appName"], "CFBundleDisplayName": value["appName"]}
    for key, item in expected.items():
        if info.get(key) != item:
            raise RuntimeError(f"应用身份发生变化：{key} 必须为 {item}。")
    return info


def verify(app, value=None):
    value = value or config()
    check_bundle(app, value)
    expected = requirement(value)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", "=" + expected, app])
    detail = run(["/usr/bin/codesign", "-d", "-r-", app])
    actual = re.search(r"^#?\s*designated => (.+)$", detail, re.MULTILINE)
    canonical = run(["/usr/bin/csreq", "-r", "=" + expected, "-t"])
    if not actual or actual.group(1) != canonical:
        raise RuntimeError("应用的 Designated Requirement 与固定身份不一致。")
    return canonical


def check_signer(value):
    sha1 = fingerprint(value)
    if not KEYCHAIN.is_file() or not PASSWORD.is_file():
        raise RuntimeError("固定签名的钥匙串或密码文件缺失。请恢复 Signing 目录的备份；不会自动生成另一张证书。")
    password = PASSWORD.read_text().strip()
    SECRETS.append(password)
    return sha1, password


def sign(app):
    value = config()
    check_bundle(app, value)
    sha1, password = check_signer(value)
    with (SIGNING / "signing.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
        added = str(KEYCHAIN) not in current
        try:
            # codesign also needs the self-signed chain in its search list, even with --keychain.
            if added:
                run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *current, KEYCHAIN])
            run(["/usr/bin/security", "unlock-keychain", "-p", password, KEYCHAIN])
            run(["/usr/bin/codesign", "--force", "--sign", sha1, "--keychain", KEYCHAIN,
                 "--identifier", value["bundleIdentifier"], "--options", "runtime", "--timestamp=none",
                 "--requirements", "=designated => " + requirement(value), app])
        finally:
            try:
                run(["/usr/bin/security", "lock-keychain", KEYCHAIN])
            finally:
                if added:
                    current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
                    run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *[p for p in current if p != str(KEYCHAIN)]])
    verify(app, value)
    print(f"固定签名验证通过：{app}")


def init_local():
    value = config()
    if value.get("certificateSHA1"):
        check_signer(value)
        print("已固定本机证书；保留现有身份，不重新生成。")
        return
    if SIGNING.exists():
        raise RuntimeError("Signing 目录已存在但项目尚未记录指纹。请检查已有证书，不能直接覆盖或重新生成。")
    os.umask(0o077)
    SIGNING.mkdir(parents=True, mode=0o700)
    password = secrets.token_urlsafe(48)
    SECRETS.append(password)
    PASSWORD.write_text(password + "\n")
    try:
        with tempfile.TemporaryDirectory(prefix="qingjie-signing-") as directory:
            temporary = Path(directory)
            openssl_config = temporary / "certificate.cnf"
            openssl_config.write_text(f"""[req]
prompt = no
distinguished_name = subject
x509_extensions = signing
[subject]
CN = {value['certificateName']}
O = QingJie Local Development
[signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
""")
            key, cert, archive = temporary / "private.pem", temporary / "certificate.pem", temporary / "identity.p12"
            run([OPENSSL, "req", "-new", "-newkey", "rsa:3072", "-nodes", "-x509", "-sha256", "-days", "3650",
                 "-config", openssl_config, "-keyout", key, "-out", cert])
            run([OPENSSL, "pkcs12", "-export", "-inkey", key, "-in", cert, "-name", value["certificateName"],
                 "-out", archive, "-passout", "file:" + str(PASSWORD)])
            run(["/usr/bin/security", "create-keychain", "-p", password, KEYCHAIN])
            run(["/usr/bin/security", "set-keychain-settings", "-lut", "300", KEYCHAIN])
            run(["/usr/bin/security", "import", archive, "-k", KEYCHAIN, "-P", password, "-T", "/usr/bin/codesign"])
            run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,codesign:", "-s", "-k", password, KEYCHAIN])
            # Retain only the public certificate on disk; the private key lives in the dedicated keychain.
            shutil.copyfile(cert, SIGNING / "certificate.pem")
            sha1 = run([OPENSSL, "x509", "-in", cert, "-noout", "-fingerprint", "-sha1"]).split("=")[-1].replace(":", "").upper()
            value["certificateSHA1"] = sha1
            CONFIG.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        print("已创建并固定本机代码签名证书（有效期 10 年）。未添加系统信任或修改屏幕权限。")
        print(f"签名资料：{SIGNING}；请保留并备份整个目录。")
        print(f"证书指纹：{sha1}")
    finally:
        if KEYCHAIN.exists():
            run(["/usr/bin/security", "lock-keychain", KEYCHAIN])
            # create-keychain may add it to the search list; do not change normal app identity lookup.
            current = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"]))
            if str(KEYCHAIN) in current:
                run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *[p for p in current if p != str(KEYCHAIN)]])


def running_executables():
    return run(["/bin/ps", "-axo", "comm="]).splitlines()


def installed_is_running(value):
    return any(path.endswith("/Contents/MacOS/" + value["executable"]) for path in running_executables())


def quit_installed(value, timeout=15.0):
    """让正在运行的轻截优雅退出；返回之前是否在运行。"""
    if not installed_is_running(value):
        return False
    try:
        run(["/usr/bin/osascript", "-e", f'tell application id "{value["bundleIdentifier"]}" to quit'])
    except RuntimeError:
        raise RuntimeError("无法向轻截发送退出事件（终端可能未获自动化授权）；"
                           "请手动退出轻截后运行 ./scripts/install.sh，或在弹窗中允许控制。")
    deadline = time.monotonic() + timeout
    while installed_is_running(value) and time.monotonic() < deadline:
        time.sleep(0.2)
    if installed_is_running(value):
        raise RuntimeError("轻截未能自动退出，已停止替换安装；请手动退出后重试。")
    return True


def publish_directory(staged, destination):
    """Replace the whole verified bundle; roll back if the second rename fails."""
    backup = staged.parent / "previous.app"
    if destination.exists():
        destination.rename(backup)
    try:
        staged.rename(destination)
    except BaseException:
        if backup.exists():
            backup.rename(destination)
        raise


def build(install_after=True):
    value = config()
    check_signer(value)
    destination = ROOT / "dist" / (value["appName"] + ".app")
    if str(destination / "Contents/MacOS" / value["executable"]) in running_executables():
        raise RuntimeError("dist 中的轻截正在运行。请先退出；日常使用应启动 /Applications/轻截.app。")
    os.chdir(ROOT)
    run(["swift", "build", "-c", "release"], capture=False)
    binary_directory = Path(run(["swift", "build", "-c", "release", "--show-bin-path"]))
    destination.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".qingjie-build-", dir=destination.parent) as directory:
        temporary = Path(directory)
        staged = temporary / destination.name
        (staged / "Contents/MacOS").mkdir(parents=True)
        (staged / "Contents/Resources").mkdir()
        shutil.copy2(binary_directory / value["executable"], staged / "Contents/MacOS" / value["executable"])
        info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        info["QingJieInstallPath"] = value["installPath"]
        # 应用内更新用同一固定身份校验下载包；指纹来源仍是 AppIdentity.json。
        info["QingJieCertificateSHA1"] = fingerprint(value)
        # Compile the editable Icon Composer document, including native appearance
        # stacks for macOS 26 and the ICNS fallback for earlier supported systems.
        icon_info = temporary / "AppIcon-Info.plist"
        run(["xcrun", "actool", ROOT / "Resources/AppIcon.icon",
             "--compile", staged / "Contents/Resources", "--platform", "macosx",
             "--minimum-deployment-target", info["LSMinimumSystemVersion"],
             "--app-icon", "AppIcon", "--output-partial-info-plist", icon_info])
        info.update(plistlib.loads(icon_info.read_bytes()))
        for name in ("Assets.car", "AppIcon.icns"):
            if not (staged / "Contents/Resources" / name).is_file():
                raise RuntimeError(f"Icon Composer 图标编译缺少 {name}。")
        (staged / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        sign(staged)
        publish_directory(staged, destination)
    if not install_after:
        print(f"已构建：{destination}\n安装更新：./scripts/install.sh")
        return
    # 每次构建都替换当前安装：先优雅退出运行中的轻截，再走 install 的完整校验替换，最后重启。
    was_running = quit_installed(value)
    install()
    if was_running:
        run(["/usr/bin/open", value["installPath"]])
    print(f"已构建并替换当前安装：{value['installPath']}")


def install():
    value = config()
    source = ROOT / "dist" / (value["appName"] + ".app")
    destination = Path(value["installPath"])
    verify(source, value)
    if installed_is_running(value):
        raise RuntimeError("请先退出轻截，再安装更新，以免运行中的版本与磁盘版本不一致。")
    if destination.is_symlink():
        raise RuntimeError("固定安装位置是符号链接，请先检查，安装已停止。")
    if destination.exists():
        verify(destination, value)
    with tempfile.TemporaryDirectory(prefix=".qingjie-install-", dir=destination.parent) as directory:
        staged = Path(directory) / destination.name
        run(["/usr/bin/ditto", source, staged])
        verify(staged, value)
        publish_directory(staged, destination)
    print(f"已安装并验证固定身份：{destination}")


def package():
    value = config()
    app = ROOT / "dist" / (value["appName"] + ".app")
    verify(app, value)
    archive = archive_path(value)
    with tempfile.TemporaryDirectory(prefix=".qingjie-package-", dir=app.parent) as directory:
        staged = Path(directory) / archive.name
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, staged])
        with zipfile.ZipFile(staged) as bundle:
            for suffix in ("Contents/Info.plist", "Contents/MacOS/" + value["executable"]):
                entry = next(name for name in bundle.namelist() if name.endswith(".app/" + suffix))
                if bundle.read(entry) != (app / suffix).read_bytes():
                    raise RuntimeError("压缩包与经过身份验证的应用不一致。")
            if bundle.testzip() is not None:
                raise RuntimeError("压缩包完整性检查失败。")
        staged.replace(archive)
    print(f"本机签名版已打包并验证：{archive}")


def archive_path(value):
    # 发布资产用 ASCII 文件名，避免下载地址出现百分号编码。
    name = value.get("archiveName") or (value["appName"] + "-macOS-arm64")
    return ROOT / "dist" / (name + ".zip")


def release_assets(args, value):
    """用 gh CLI 把压缩包上传为 GitHub Release 资产，返回 (package_url, release_url)。"""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.github_repo or ""):
        raise RuntimeError("--github-repo 需要形如 owner/name。")
    gh = shutil.which("gh")
    if not gh:
        raise RuntimeError("未找到 gh CLI；请先安装并 gh auth login，或改用 --package-url 手动指定地址。")
    archive = archive_path(value)
    if not archive.is_file():
        raise RuntimeError("缺少发布压缩包；请先运行 python3 scripts/app_identity.py package。")
    info = plistlib.loads((ROOT / "dist" / (value["appName"] + ".app") / "Contents/Info.plist").read_bytes())
    tag = args.tag or ("v" + info["CFBundleShortVersionString"])
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", tag):
        raise RuntimeError("无效的发布标签。")
    title = info["CFBundleShortVersionString"]
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    prefix = value.get("archiveName") or (value["appName"] + "-macOS-arm64")
    # 不再覆盖固定文件名；旧客户端手中的 URL 必须始终对应原来的字节。
    asset_name = f'{prefix}-{title}-build{info["CFBundleVersion"]}-{digest[:12]}.zip'
    release = github_release(gh, args.github_repo, tag)
    if release is not None:
        assets = release.get("assets", [])
        existing = next((asset for asset in assets if asset["name"] == asset_name), None)
        if existing is not None:
            verify_release_asset(existing, archive, digest)
            return existing["browser_download_url"], release["html_url"]
        if any(asset["name"].startswith(prefix) and asset["name"].endswith(".zip") for asset in assets):
            raise RuntimeError("该 Release 已有不同的安装包，禁止覆盖。请递增版本/build 并使用新的 Release 标签。")
    with tempfile.TemporaryDirectory(prefix="qingjie-release-") as directory:
        upload = Path(directory) / asset_name
        shutil.copyfile(archive, upload)
        if release is None:
            run([gh, "release", "create", tag, str(upload), "--repo", args.github_repo,
                 "--title", title, "--notes", args.notes or title])
        else:
            run([gh, "release", "upload", tag, str(upload), "--repo", args.github_repo])
    release = github_release(gh, args.github_repo, tag)
    asset = next((asset for asset in (release or {}).get("assets", []) if asset["name"] == asset_name), None)
    if asset is None:
        raise RuntimeError("上传后未找到安装包，停止生成更新源。")
    verify_release_asset(asset, archive, digest)
    print(f"压缩包已上传并核对 GitHub SHA-256：{args.github_repo} {tag}")
    return asset["browser_download_url"], release["html_url"]


def github_release(gh, repository, tag):
    try:
        return json.loads(run([gh, "api", f"repos/{repository}/releases/tags/{tag}"]))
    except RuntimeError as error:
        if "HTTP 404" in str(error):
            return None
        raise


def verify_release_asset(asset, archive, digest):
    if (asset.get("state") != "uploaded" or asset.get("size") != archive.stat().st_size
            or asset.get("digest") != "sha256:" + digest):
        raise RuntimeError("GitHub 安装包的大小/SHA-256 与本地包不一致，停止生成更新源。")


def verify_package(archive, app, value):
    """构建后忘记重新打包时，不能把新版本信息与旧压缩包拼成更新源。"""
    with tempfile.TemporaryDirectory(prefix="qingjie-package-verify-") as directory:
        extracted = Path(directory)
        run(["/usr/bin/ditto", "-x", "-k", archive, extracted])
        packaged_app = extracted / app.name
        verify(packaged_app, value)
        for suffix in ("Contents/Info.plist", "Contents/MacOS/" + value["executable"]):
            if (packaged_app / suffix).read_bytes() != (app / suffix).read_bytes():
                raise RuntimeError("压缩包与当前构建不一致，请重新运行 package 后再发布。")


def feed(args):
    value = config()
    app = ROOT / "dist" / (value["appName"] + ".app")
    verify(app, value)
    archive = archive_path(value)
    if not archive.is_file():
        raise RuntimeError("缺少发布压缩包；请先运行 python3 scripts/app_identity.py package。")
    verify_package(archive, app, value)
    if args.github_repo:
        args.package_url, args.release_url = release_assets(args, value)
    if not args.package_url or not args.package_url.startswith("https://"):
        raise RuntimeError("需要 --package-url 指向压缩包的 https 下载地址（或 --github-repo 自动上传）。")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    payload = {"version": info["CFBundleShortVersionString"], "build": int(info["CFBundleVersion"]),
               "package": {"url": args.package_url, "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
                           "bytes": archive.stat().st_size}}
    if args.notes:
        payload["notes"] = args.notes
    if args.release_url:
        payload["url"] = args.release_url
    target = app.parent / FEED_FILE
    target.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    print(f"已生成更新源：{target}")
    return target


def publish(args):
    """上传压缩包（--github-repo）、生成 latest.json 并写入 gist，一条命令完成发版。"""
    target = feed(args)
    gh = shutil.which("gh")
    if gh:
        try:
            run([gh, "auth", "status"])
            run([gh, "api", "-X", "PATCH", f"/gists/{FEED_GIST}",
                 "-F", f"files[{FEED_FILE}][content]=@{target}"])
            print("更新源已通过 gh 发布到 gist；客户端下次检查时会看到新版本。")
            return
        except RuntimeError:
            print("gh 不可用或未授权 gist，改用 QINGJIE_GIST_TOKEN。")
    token = os.environ.get("QINGJIE_GIST_TOKEN", "").strip()
    if not token:
        raise RuntimeError("gh 不可用且缺少 QINGJIE_GIST_TOKEN 环境变量；"
                           "也可以手动把 dist/latest.json 的内容更新到 gist。")
    SECRETS.append(token)
    body = json.dumps({"files": {FEED_FILE: {"content": target.read_text()}}})
    run(["/usr/bin/curl", "-sS", "-f", "-X", "PATCH",
         "-H", f"Authorization: Bearer {token}", "-H", "Accept: application/vnd.github+json",
         "-d", body, f"https://api.github.com/gists/{FEED_GIST}"])
    print("更新源已发布到 gist；客户端下次检查时会看到新版本。")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init-local", "build", "sign", "verify", "install", "package", "feed", "publish", "status"])
    parser.add_argument("app", nargs="?", type=Path)
    parser.add_argument("--package-url", help="更新压缩包的 https 下载地址（feed/publish）")
    parser.add_argument("--release-url", help="发布页地址，可选（feed/publish）")
    parser.add_argument("--notes", help="更新说明，可选（feed/publish）")
    parser.add_argument("--github-repo", help="用 gh CLI 上传压缩包到该仓库的 Release，形如 owner/name（feed/publish）")
    parser.add_argument("--tag", help="Release 标签，默认 v<版本号>（配合 --github-repo）")
    parser.add_argument("--no-install", action="store_true", help="仅构建 dist 成品，不替换 /Applications 安装")
    args = parser.parse_args()
    if args.command in ("sign", "verify") and args.app is None:
        parser.error("需要应用路径")
    if args.command == "init-local": init_local()
    elif args.command == "build": build(install_after=not args.no_install)
    elif args.command == "sign": sign(args.app.resolve())
    elif args.command == "verify": print(verify(args.app.resolve()))
    elif args.command == "install": install()
    elif args.command == "package": package()
    elif args.command == "feed": feed(args)
    elif args.command == "publish": publish(args)
    else:
        value = config()
        print(json.dumps(value, ensure_ascii=False, indent=2))
        print("固定校验规则：" + requirement(value))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"轻截身份检查失败：{error}", file=sys.stderr)
        sys.exit(1)
