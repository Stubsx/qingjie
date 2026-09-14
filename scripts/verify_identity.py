#!/usr/bin/env python3
"""Check identity continuity with two different binaries, without launching either."""
import plistlib
from pathlib import Path
import re
import shutil
import tempfile

from app_identity import ROOT, check_bundle, config, fingerprint, requirement, run, sign, verify


def rejected(operation):
    try:
        operation()
    except RuntimeError:
        return
    raise AssertionError("应拒绝的身份被接受")


def main():
    value = config()
    with tempfile.TemporaryDirectory(prefix="qingjie-identity-test-") as directory:
        temporary = Path(directory)
        hashes, requirements, apps = [], [], []
        for revision in (1, 2):
            app = temporary / f"revision-{revision}" / (value["appName"] + ".app")
            binary = app / "Contents/MacOS" / value["executable"]
            binary.parent.mkdir(parents=True)
            source = temporary / f"revision-{revision}.c"
            source.write_text(f'int main(void) {{ return {revision}; }}\n')
            run(["xcrun", "clang", source, "-o", binary])
            info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
            info["CFBundleVersion"] = str(revision)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
            sign(app)
            requirements.append(verify(app))
            detail = run(["/usr/bin/codesign", "-d", "--verbose=4", app])
            hashes.append(re.search(r"^CDHash=(.+)$", detail, re.MULTILINE).group(1))
            apps.append(app)
        assert hashes[0] != hashes[1], "验证必须使用不同的代码哈希"
        assert requirements[0] == requirements[1], "跨版本应用身份发生变化"
        run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirements[0], apps[1]])
        print("PASS: 两个不同二进制的代码哈希不同，身份规则一致；新版通过旧版身份校验")

        unsigned = temporary / "unsigned.app"
        shutil.copytree(apps[1], unsigned)
        run(["/usr/bin/codesign", "--remove-signature", unsigned])
        rejected(lambda: verify(unsigned))
        print("PASS: 未签名应用不能冒用同名身份")

        altered = temporary / "altered.app"
        shutil.copytree(apps[1], altered)
        with (altered / "Contents/MacOS" / value["executable"]).open("ab") as file:
            file.write(b"tampered")
        rejected(lambda: verify(altered))
        print("PASS: 二进制遭篡改时签名验证失败")

        info = plistlib.loads((unsigned / "Contents/Info.plist").read_bytes())
        info["CFBundleIdentifier"] = "com.example.different"
        (unsigned / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        rejected(lambda: check_bundle(unsigned, value))
        rejected(lambda: fingerprint({**value, "certificateSHA1": None}))
        print("PASS: 更换 Bundle ID 或缺失固定证书时停止构建，不回退临时签名")
        print("固定身份：" + requirement(value))


if __name__ == "__main__":
    main()
