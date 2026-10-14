#!/usr/bin/env python3
"""Generate update.json from the signed APK, using only the Python standard library."""

import argparse
import hashlib
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

MAX_APK_BYTES = 512 * 1024 * 1024


def parse_badging(text):
    package = re.search(r"^package: (.+)$", text, re.MULTILINE)
    if not package:
        raise ValueError("aapt did not report APK package metadata")
    fields = dict(re.findall(r"(\w+)='([^']*)'", package.group(1)))
    sdk = re.search(r"^sdkVersion:'(\d+)'$", text, re.MULTILINE)
    if not sdk or not all(fields.get(key) for key in ("name", "versionName", "versionCode")):
        raise ValueError("APK version or minSdk metadata is missing")
    code = int(fields["versionCode"])
    if not 0 < code <= 2147483647:
        raise ValueError("APK versionCode must be a positive Android versionCode")
    return {
        "packageName": fields["name"],
        "versionName": fields["versionName"],
        "versionCode": code,
        "minSdk": int(sdk.group(1)),
    }


def parse_certificate(text):
    hashes = set(re.findall(r"certificate SHA-256 digest:\s*([a-fA-F0-9]{64})", text))
    if len(hashes) != 1:
        raise ValueError("APK must have exactly one signing certificate")
    return hashes.pop().lower()


def normalize_certificate(value):
    normalized = re.sub(r"[:\s]", "", value).lower()
    # Match the normalization in the release workflow (keytool label is accepted).
    normalized = normalized[-64:]
    if not re.fullmatch(r"[a-f0-9]{64}", normalized):
        raise ValueError("Expected certificate fingerprint is invalid")
    return normalized


def generate_manifest(apk, metadata, certificate, repository, tag, notes=""):
    if metadata["packageName"] != "com.streambox.streambox":
        raise ValueError("Unexpected APK application ID")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository, flags=re.ASCII):
        raise ValueError("Invalid GitHub repository")
    if tag != "v" + metadata["versionName"] or not re.fullmatch(r"v[\w.+-]+", tag, flags=re.ASCII):
        raise ValueError("Release tag must match the APK versionName (v<version>)")
    size = apk.stat().st_size
    if not 0 < size <= MAX_APK_BYTES:
        raise ValueError("APK size is outside the supported update limit")
    digest = hashlib.sha256()
    with apk.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    filename = f"StreamBox-{tag}-android.apk"
    return {
        "schemaVersion": 1,
        "platform": "android",
        **metadata,
        "downloadUrl": f"https://github.com/{repository}/releases/download/{quote(tag, safe='')}/{quote(filename, safe='')}",
        "size": size,
        "sha256": digest.hexdigest(),
        "certificateSha256": certificate,
        "releaseNotes": notes[:16000],
        "publishedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--aapt", required=True)
    parser.add_argument("--apksigner", required=True)
    parser.add_argument("--expected-certificate", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--notes-file", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    badging = subprocess.run(
        [args.aapt, "dump", "badging", str(args.apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    signing = subprocess.run(
        [args.apksigner, "verify", "--print-certs", str(args.apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    certificate = parse_certificate(signing)
    if certificate != normalize_certificate(args.expected_certificate):
        raise ValueError("APK signing certificate does not match the pinned release certificate")
    notes = args.notes_file.read_text(encoding="utf-8") if args.notes_file else ""
    manifest = generate_manifest(
        args.apk, parse_badging(badging), certificate, args.repository, args.tag, notes,
    )
    payload = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    if len(payload.encode("utf-8")) > 64 * 1024:
        raise ValueError("Manifest exceeds the client response limit")
    args.output.write_text(payload, encoding="utf-8")


if __name__ == "__main__":
    main()
