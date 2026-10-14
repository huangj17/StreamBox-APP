import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "manifest", Path(__file__).resolve().parents[1] / "generate_update_manifest.py",
)
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class ManifestTest(unittest.TestCase):
    def test_reads_actual_apk_metadata(self):
        metadata = manifest.parse_badging(
            "package: name='com.streambox.streambox' versionCode='12' versionName='1.2.0' platformBuildVersionName='16'\n"
            "sdkVersion:'23'\n",
        )
        self.assertEqual(metadata["versionCode"], 12)
        self.assertEqual(metadata["versionName"], "1.2.0")
        self.assertEqual(metadata["minSdk"], 23)

    def test_certificate_output_variants_and_missing_signer(self):
        digest = "ab" * 32
        for label in ("Signer #1", "Signer (minSdkVersion=24, maxSdkVersion=32) #1"):
            self.assertEqual(manifest.parse_certificate(f"{label} certificate SHA-256 digest: {digest}"), digest)
        with self.assertRaises(ValueError):
            manifest.parse_certificate("unsigned")
        with self.assertRaises(ValueError):
            manifest.parse_certificate(f"Signer #1 certificate SHA-256 digest: {digest}\nSigner #2 certificate SHA-256 digest: {'cd' * 32}")
        self.assertEqual(manifest.normalize_certificate("SHA-256: " + ":".join(["AB"] * 32)), digest)

    def test_digest_size_notes_and_immutable_download_url(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            apk.write_bytes(b"signed-apk-fixture")
            metadata = manifest.parse_badging(
                "package: name='com.streambox.streambox' versionCode='5' versionName='0.4.1'\nsdkVersion:'23'\n",
            )
            value = manifest.generate_manifest(apk, metadata, "ab" * 32, "huangj17/StreamBox-APP", "v0.4.1", "修复遥控操作\n支持升级")
            self.assertEqual(value["sha256"], hashlib.sha256(apk.read_bytes()).hexdigest())
            self.assertEqual(value["size"], apk.stat().st_size)
            self.assertEqual(value["releaseNotes"], "修复遥控操作\n支持升级")
            self.assertEqual(value["downloadUrl"], "https://github.com/huangj17/StreamBox-APP/releases/download/v0.4.1/StreamBox-v0.4.1-android.apk")
            with self.assertRaises(ValueError):
                manifest.generate_manifest(apk, metadata, "ab" * 32, "huangj17/StreamBox-APP", "v0.5.0")
            with self.assertRaises(ValueError):
                manifest.generate_manifest(apk, metadata, "ab" * 32, "../invalid/repo", "v0.4.1")


if __name__ == "__main__":
    unittest.main()
