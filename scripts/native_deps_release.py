#!/usr/bin/env python3
"""Manage prebuilt iOS native dependencies as GitHub Release assets.

Subcommands:
  key       Print deterministic tag/key for current deps inputs.
  download  Fetch and extract prebuilt deps from GitHub Releases if present;
            writes hit=true|false, key, tag to GITHUB_OUTPUT.
  publish   Package built deps dirs and upload to GitHub Releases.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
FORMAT_VERSION = "native-deps-v1"
AOT_TAG = "aot-1f3bb5a0"

ARCHIVE_DIRS = [
    "deps/libs",
    "deps/include",
    "deps/frameworks",
    "deps/resources",
    "deps/lame-build",
]

SENTINELS = [
    "deps/libs/libish_aot.a",
    "deps/libs/libish_emu.a",
    "deps/frameworks/FFmpeg.xcframework/Info.plist",
    "deps/frameworks/Rclone.xcframework/Info.plist",
    "deps/resources/alpine-rootfs.zip",
    "deps/resources/RootfsPatch.bundle",
    "deps/lame-build/lib/libmp3lame.a",
]

KEY_PATHSPECS = [
    ".gitmodules",
    "deps/*.sh",
    "deps/aot/README.md",
    "deps/ffmpeg-patch",
    "deps/rclone-mobile",
    "deps/talloc",
    "deps/lame-3.100",
    "deps/ish",
]


def compute_deps_key() -> str:
    """Compute a deterministic hash from tracked git index entries only.

    Using `git ls-files -s` ensures the key is identical before and after
    in-tree builds (e.g. lame's ./configure && make) and ignores submodule
    .git pointer files.
    """
    out = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-s", "--", *KEY_PATHSPECS],
    )
    h = hashlib.sha256()
    h.update(f"{FORMAT_VERSION}\0{AOT_TAG}\0".encode())
    h.update(out)
    return h.hexdigest()[:16]


def release_names(key: str) -> tuple[str, str, str]:
    tag = f"native-deps-{key}"
    archive_name = f"{tag}.tar.xz"
    sha_name = f"{archive_name}.sha256"
    return tag, archive_name, sha_name


def set_output(values: dict[str, str]) -> None:
    out_path = os.environ.get("GITHUB_OUTPUT")
    if out_path:
        with open(out_path, "a", encoding="utf-8") as f:
            for k, v in values.items():
                f.write(f"{k}={v}\n")


def api_request(
    url: str,
    token: str,
    method: str = "GET",
    payload: dict | None = None,
) -> tuple[int, dict | list | None]:
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            body = r.read()
            return r.status, json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        try:
            err_json = json.loads(raw) if raw else None
        except Exception:
            err_json = {"raw": raw[:400]}
        return e.code, err_json


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def verify_sentinels() -> list[str]:
    missing = []
    for rel in SENTINELS:
        if not (ROOT / rel).exists():
            missing.append(rel)
    return missing


def curl_download(url: str, token: str, dest: pathlib.Path) -> None:
    subprocess.run(
        [
            "curl",
            "-fsSL",
            "--retry",
            "6",
            "--retry-delay",
            "8",
            "--retry-all-errors",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Accept: application/octet-stream",
            "-o",
            str(dest),
            url,
        ],
        check=True,
    )


def curl_upload(upload_url: str, token: str, src: pathlib.Path) -> None:
    subprocess.run(
        [
            "curl",
            "-fsSL",
            "--retry",
            "5",
            "--retry-delay",
            "5",
            "--retry-all-errors",
            "-X",
            "POST",
            "-H",
            f"Authorization: Bearer {token}",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "Content-Type: application/octet-stream",
            "--data-binary",
            f"@{src}",
            "-o",
            "/dev/null",
            upload_url,
        ],
        check=True,
    )


def cmd_key() -> int:
    key = compute_deps_key()
    tag, archive_name, _ = release_names(key)
    print(json.dumps({"key": key, "tag": tag, "archive": archive_name}))
    return 0


def cmd_download() -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "GP1250409/OpenMinis")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN_GP1250409", "")
    key = compute_deps_key()
    tag, archive_name, sha_name = release_names(key)
    set_output({"key": key, "tag": tag})

    if not token:
        print("PREBUILT_DEPS_MISS reason=no_token")
        set_output({"hit": "false"})
        return 0

    api_base = f"https://api.github.com/repos/{repo}"
    status, rel = api_request(f"{api_base}/releases/tags/{tag}", token)
    if status == 404 or not isinstance(rel, dict):
        print(f"PREBUILT_DEPS_MISS tag={tag} status={status}")
        set_output({"hit": "false"})
        return 0
    if status != 200:
        print(f"PREBUILT_DEPS_MISS tag={tag} http={status}")
        set_output({"hit": "false"})
        return 0

    assets = {a["name"]: a for a in rel.get("assets", [])}
    tar_asset = assets.get(archive_name)
    sha_asset = assets.get(sha_name)
    if not tar_asset or not sha_asset or tar_asset.get("size", 0) < 1024 * 1024:
        print(f"PREBUILT_DEPS_MISS tag={tag} reason=incomplete_assets")
        set_output({"hit": "false"})
        return 0

    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = pathlib.Path(tmp)
        tar_path = tmp_dir / archive_name
        sha_path = tmp_dir / sha_name
        try:
            curl_download(f"{api_base}/releases/assets/{sha_asset['id']}", token, sha_path)
            curl_download(f"{api_base}/releases/assets/{tar_asset['id']}", token, tar_path)
        except subprocess.CalledProcessError as e:
            print(f"PREBUILT_DEPS_MISS tag={tag} reason=download_failed rc={e.returncode}")
            set_output({"hit": "false"})
            return 0

        expected_sha = sha_path.read_text(encoding="utf-8").strip().split()[0].lower()
        actual_sha = sha256_file(tar_path).lower()
        actual_size = tar_path.stat().st_size
        if actual_sha != expected_sha or actual_size != tar_asset["size"]:
            print(
                f"PREBUILT_DEPS_MISS tag={tag} reason=checksum_mismatch "
                f"size={actual_size}/{tar_asset['size']}"
            )
            set_output({"hit": "false"})
            return 0

        subprocess.run(["tar", "-xJf", str(tar_path), "-C", str(ROOT)], check=True)

    missing = verify_sentinels()
    if missing:
        print(f"PREBUILT_DEPS_MISS tag={tag} reason=missing_sentinels missing={missing}")
        set_output({"hit": "false"})
        return 0

    print(f"PREBUILT_DEPS_HIT tag={tag} size={tar_asset['size']} sha256={actual_sha[:12]}")
    set_output({"hit": "true"})
    return 0


def cmd_publish() -> int:
    repo = os.environ.get("GITHUB_REPOSITORY", "GP1250409/OpenMinis")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN_GP1250409", "")
    if not token:
        print("ERROR: GH_TOKEN missing for publish", file=sys.stderr)
        return 1

    missing = verify_sentinels()
    if missing:
        print(f"ERROR: cannot publish, missing sentinels: {missing}", file=sys.stderr)
        return 1

    key = compute_deps_key()
    tag, archive_name, sha_name = release_names(key)
    api_base = f"https://api.github.com/repos/{repo}"

    status, rel = api_request(f"{api_base}/releases/tags/{tag}", token)
    if status == 404:
        sha = os.environ.get("GITHUB_SHA", "")
        body = (
            f"Prebuilt iOS native dependencies (`{ARCHIVE_DIRS}`) for key `{key}`.\n\n"
            f"- AOT images: `{AOT_TAG}`\n"
            f"- Built from commit: `{sha or 'manual'}`\n"
        )
        payload = {
            "tag_name": tag,
            "name": f"Prebuilt native deps ({key})",
            "body": body,
            "draft": False,
            "prerelease": False,
        }
        if sha:
            payload["target_commitish"] = sha
        c_status, c_rel = api_request(f"{api_base}/releases", token, method="POST", payload=payload)
        if c_status == 422:
            status, rel = api_request(f"{api_base}/releases/tags/{tag}", token)
        elif c_status in (200, 201) and isinstance(c_rel, dict):
            status, rel = 200, c_rel
        else:
            print(f"ERROR: create release failed http={c_status} resp={c_rel}", file=sys.stderr)
            return 1

    if status != 200 or not isinstance(rel, dict):
        print(f"ERROR: get release failed http={status} resp={rel}", file=sys.stderr)
        return 1

    existing = {a["name"]: a for a in rel.get("assets", [])}
    if (
        archive_name in existing
        and sha_name in existing
        and existing[archive_name].get("size", 0) > 10 * 1024 * 1024
    ):
        print(f"PREBUILT_DEPS_ALREADY_PUBLISHED tag={tag}")
        return 0

    upload_base = rel["upload_url"].split("{", 1)[0]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_dir = pathlib.Path(tmp)
        tar_path = tmp_dir / archive_name
        sha_path = tmp_dir / sha_name
        present_dirs = [d for d in ARCHIVE_DIRS if (ROOT / d).exists()]
        subprocess.run(["tar", "-cJf", str(tar_path), *present_dirs], cwd=ROOT, check=True)
        digest = sha256_file(tar_path)
        sha_path.write_text(f"{digest}  {archive_name}\n", encoding="utf-8")

        for local_file in (tar_path, sha_path):
            if local_file.name in existing:
                d_status, _ = api_request(
                    f"{api_base}/releases/assets/{existing[local_file.name]['id']}",
                    token,
                    method="DELETE",
                )
                if d_status not in (200, 204, 404):
                    print(f"WARN: delete old asset {local_file.name} http={d_status}")
            curl_upload(f"{upload_base}?name={local_file.name}", token, local_file)

        print(
            f"PREBUILT_DEPS_PUBLISHED tag={tag} size={tar_path.stat().st_size} sha256={digest[:12]}"
        )
    return 0


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("key", "download", "publish"):
        print("Usage: native_deps_release.py <key|download|publish>", file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    if cmd == "key":
        return cmd_key()
    if cmd == "download":
        return cmd_download()
    return cmd_publish()


if __name__ == "__main__":
    raise SystemExit(main())
