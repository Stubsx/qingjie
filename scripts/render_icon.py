#!/usr/bin/env python3
"""Render review images with Icon Composer's native macOS 26 effects."""
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    renderer = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    if not renderer.is_file():
        raise SystemExit("需要安装包含 Icon Composer 的 Xcode 26 或更新版本。")
    destination = root / "dist/qa/icon-composer"
    destination.mkdir(parents=True, exist_ok=True)
    for appearance, size, filename in (
        ("Default", 512, "default.png"),
        ("Dark", 512, "dark.png"),
        ("Mono", 512, "mono.png"),
        ("Default", 32, "small.png"),
        ("Default", 256, "preview.png"),
    ):
        subprocess.run([
            str(renderer), str(root / "Resources/AppIcon.icon"), "--export-image",
            "--output-file", str(destination / filename), "--platform", "macOS",
            "--rendition", appearance, "--width", str(size), "--height", str(size),
            "--scale", "1", "--design-generation", "26",
        ], check=True, capture_output=True)
    print(f"已生成 macOS 26 图标预览：{destination}")


if __name__ == "__main__":
    main()
