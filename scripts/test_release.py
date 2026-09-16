"""发布回归测试：只使用临时文件和模拟 GitHub，不上传或修改线上数据。"""
import hashlib
import plistlib
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

import app_identity as identity


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.value = {"appName": "轻截", "executable": "QingJie", "archiveName": "qingjie-macOS-arm64"}
        self.app = self.root / "dist/轻截.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.6.18", "CFBundleVersion": "27"}))
        (self.app / "Contents/MacOS/QingJie").write_bytes(b"new binary")
        self.archive = self.root / "dist/qingjie-macOS-arm64.zip"
        self.archive.write_bytes(b"signed package fixture")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.asset = {"name": f"qingjie-macOS-arm64-0.6.18-build27-{self.digest[:12]}.zip",
                      "size": self.archive.stat().st_size, "digest": "sha256:" + self.digest,
                      "state": "uploaded", "browser_download_url": "https://example.com/immutable.zip"}
        self.release = {"html_url": "https://example.com/release", "assets": [self.asset]}
        self.args = SimpleNamespace(github_repo="owner/repo", tag=None, notes="fix")
        root_patch = patch.object(identity, "ROOT", self.root)
        root_patch.start()
        self.addCleanup(root_patch.stop)
        gh_patch = patch.object(identity.shutil, "which", return_value="/bin/gh")
        gh_patch.start()
        self.addCleanup(gh_patch.stop)

    def test_existing_different_package_is_never_overwritten(self):
        old = {**self.asset, "name": "qingjie-macOS-arm64.zip"}
        with patch.object(identity, "github_release", return_value={**self.release, "assets": [old]}), patch.object(identity, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "禁止覆盖"):
                identity.release_assets(self.args, self.value)
            run.assert_not_called()

    def test_identical_release_can_be_reused_without_upload(self):
        with patch.object(identity, "github_release", return_value=self.release), patch.object(identity, "run") as run:
            urls = identity.release_assets(self.args, self.value)
            self.assertEqual(urls[0], self.asset["browser_download_url"])
            run.assert_not_called()

    def test_new_release_uses_unique_filename_and_verifies_upload(self):
        with patch.object(identity, "github_release", side_effect=[None, self.release]), patch.object(identity, "run") as run:
            identity.release_assets(self.args, self.value)
            command = run.call_args.args[0]
            self.assertEqual(command[1:4], ["release", "create", "v0.6.18"])
            self.assertEqual(Path(command[4]).name, self.asset["name"])
            self.assertNotIn("--clobber", command)

    def test_remote_digest_mismatch_aborts(self):
        bad = {**self.release, "assets": [{**self.asset, "digest": "sha256:wrong"}]}
        with patch.object(identity, "github_release", side_effect=[None, bad]), patch.object(identity, "run"):
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                identity.release_assets(self.args, self.value)

    def test_network_error_is_not_treated_as_missing_release(self):
        with patch.object(identity, "run", side_effect=RuntimeError("HTTP 403")) as run:
            with self.assertRaisesRegex(RuntimeError, "HTTP 403"):
                identity.release_assets(self.args, self.value)
            self.assertEqual(run.call_count, 1)

    def test_old_archive_cannot_be_paired_with_new_build(self):
        def extract(command):
            extracted = Path(command[-1]) / self.app.name
            (extracted / "Contents/MacOS").mkdir(parents=True)
            (extracted / "Contents/Info.plist").write_bytes((self.app / "Contents/Info.plist").read_bytes())
            (extracted / "Contents/MacOS/QingJie").write_bytes(b"old binary")
        with patch.object(identity, "run", side_effect=extract), patch.object(identity, "verify"):
            with self.assertRaisesRegex(RuntimeError, "重新运行 package"):
                identity.verify_package(self.archive, self.app, self.value)


if __name__ == "__main__":
    unittest.main()
