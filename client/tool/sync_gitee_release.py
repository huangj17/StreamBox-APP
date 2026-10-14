#!/usr/bin/env python3
"""Copy already-built GitHub APKs to Gitee using its v5 Release API."""

import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import Request, urlopen
import uuid


class GiteeAPI:
    def __init__(self, repository, token):
        if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
            raise ValueError("GITEE_REPOSITORY must be owner/repository")
        if not token:
            raise ValueError("GITEE_TOKEN is required")
        self.base = f"https://gitee.com/api/v5/repos/{repository}"
        self.token = token

    def request(self, method, path, fields=None, file=None, allow_missing=False):
        fields = {**(fields or {}), "access_token": self.token}
        url = self.base + path
        headers = {"Accept": "application/json"}
        data = None
        if method in ("GET", "DELETE"):
            url += "?" + urlencode(fields)
        elif file is not None:
            boundary = uuid.uuid4().hex
            parts = []
            for name, value in fields.items():
                parts.append(
                    f'--{boundary}\r\nContent-Disposition: form-data; '
                    f'name="{name}"\r\n\r\n{value}\r\n'.encode()
                )
            parts.append(
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; '
                f'filename="{file.name}"\r\nContent-Type: '
                'application/vnd.android.package-archive\r\n\r\n'.encode()
            )
            parts.extend([file.read_bytes(), f"\r\n--{boundary}--\r\n".encode()])
            data = b"".join(parts)
            headers["Content-Type"] = f"multipart/form-data; boundary={boundary}"
        else:
            data = urlencode(fields).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        try:
            with urlopen(Request(url, data=data, headers=headers, method=method), timeout=300) as response:
                body = response.read()
                return json.loads(body) if body else None
        except HTTPError as error:
            if allow_missing and error.code == 404:
                return None
            # HTTPError includes the request URL, which can contain the token.
            raise RuntimeError(f"Gitee {method} {path.split('?')[0]} failed: HTTP {error.code}") from None
        except URLError:
            raise RuntimeError("Cannot connect to Gitee; rerun Sync to Gitee when connectivity recovers") from None

    def attachments(self, release_id):
        items = []
        page = 1
        while True:
            batch = self.request("GET", f"/releases/{release_id}/attach_files",
                                 {"page": page, "per_page": 100})
            items.extend(batch)
            if len(batch) < 100:
                return items
            page += 1


def synchronize(api, directory):
    metadata = json.loads((directory / "release.json").read_text())
    if metadata.get("isDraft"):
        raise ValueError("Draft releases must not be published to Gitee")
    apks = sorted(directory.glob("*.apk"))
    if not apks:
        raise ValueError("No APK found; GitHub must finish uploading the APK first")
    for apk in apks:
        if not re.fullmatch(r"[A-Za-z0-9_.+-]+\.apk", apk.name) or apk.stat().st_size == 0:
            raise ValueError("APK filename is unsafe or the APK is empty")
    tag = metadata["tagName"]
    fields = {
        "tag_name": tag,
        "name": metadata.get("name") or tag,
        "body": metadata.get("body") or f"StreamBox {tag}",
        "prerelease": str(metadata.get("isPrerelease", False)).lower(),
    }
    release = api.request("GET", f"/releases/tags/{quote(tag, safe='')}", allow_missing=True)
    if release is None:
        release = api.request("POST", "/releases", {**fields, "target_commitish": tag})
    else:
        api.request("PATCH", f"/releases/{release['id']}", fields)
    release_id = release["id"]
    attachments = api.attachments(release_id)
    for apk in apks:
        # Manual rebuilds may replace the same APK name. Keep unrelated files.
        for attachment in attachments:
            if attachment["name"] == apk.name:
                api.request("DELETE", f"/releases/{release_id}/attach_files/{attachment['id']}")
        api.request("POST", f"/releases/{release_id}/attach_files", file=apk)
        print(f"Uploaded {apk.name} to Gitee Release {tag}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    args = parser.parse_args()
    try:
        api = GiteeAPI(os.environ.get("GITEE_REPOSITORY", ""), os.environ.get("GITEE_TOKEN", ""))
        synchronize(api, args.directory)
    except (ValueError, OSError, RuntimeError, KeyError) as error:
        print(f"Gitee release synchronization failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
