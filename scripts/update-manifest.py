#!/usr/bin/env python3
"""Build and Ed25519-sign a GitHub release's installer and remote helper manifest."""

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path
from urllib.parse import quote

ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
SEMVER = re.compile(
    r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def openssl(*args):
    result = subprocess.run(
        ["openssl", *map(str, args)], check=True, capture_output=True
    )
    return result.stdout


def build_manifest(args):
    version = args.tag.removeprefix("v")
    match = SEMVER.fullmatch(version)
    if not match or any(
        part.isdigit() and len(part) > 1 and part.startswith("0")
        for part in (match[4] or "").split(".")
    ):
        raise ValueError("Release tags must contain a SemVer version, such as v1.2.3.")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo):
        raise ValueError("Repository must use owner/name format.")
    packages = args.packages
    base = f"https://github.com/{args.repo}/releases/download/{quote(args.tag, safe='')}"
    targets = [
        ("linux", "amd64", "deb", f"task_master_{version}_amd64.deb"),
        ("linux", "arm64", "deb", f"task_master_{version}_arm64.deb"),
        ("linux", "amd64", "appimage", f"task_master-{version}-x86_64.AppImage"),
        ("linux", "arm64", "appimage", f"task_master-{version}-aarch64.AppImage"),
        ("windows", "amd64", "windows", f"task_master-{version}-windows-x64-setup.exe"),
        ("windows", "arm64", "windows", f"task_master-{version}-windows-arm64-setup.exe"),
        ("darwin", "amd64", "macos", f"task_master-{version}-amd64.pkg"),
        ("darwin", "arm64", "macos", f"task_master-{version}-arm64.pkg"),
    ]
    targets.extend(
        (os_name, arch, "collector", f"task_master-collector-{os_name}-{arch}")
        for os_name in ("linux", "darwin", "windows")
        for arch in ("amd64", "arm64")
    )
    targets.extend(
        ("windows", arch, "sensors", f"task_master-windows-sensors-{arch}.zip")
        for arch in ("amd64", "arm64")
    )
    assets = []
    for os_name, arch, kind, name in targets:
        package = packages / name
        if not package.is_file() or package.stat().st_size == 0:
            raise ValueError(f"Missing or empty release asset: {package}")
        digest = hashlib.sha256()
        with package.open("rb") as handle:
            for block in iter(lambda: handle.read(4 * 1024 * 1024), b""):
                digest.update(block)
        assets.append({
            "os": os_name, "arch": arch, "kind": kind, "name": name,
            "size": package.stat().st_size, "sha256": digest.hexdigest(),
            "url": f"{base}/{quote(name, safe='')}",
        })
    return {"schema": 1, "version": version, "assets": assets}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", default="sion3951/task_master")
    parser.add_argument("--packages", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, default=Path("assets/update-public-key.hex"))
    args = parser.parse_args()
    try:
        public_key = bytes.fromhex(args.public_key.read_text().strip())
        if len(public_key) != 32:
            raise ValueError("Embedded Ed25519 public key must contain exactly 32 bytes.")
        actual_public = openssl("pkey", "-in", args.private_key, "-pubout", "-outform", "DER")
        if actual_public != ED25519_SPKI_PREFIX + public_key:
            raise ValueError("Signing key does not match assets/update-public-key.hex.")
        manifest = build_manifest(args)
        # The exact bytes are signed; clients must verify before parsing JSON.
        payload = (json.dumps(manifest, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")
        with tempfile.TemporaryDirectory(prefix="task-master-update-") as temporary:
            temporary = Path(temporary)
            staged_manifest = temporary / "update.json"
            staged_signature = temporary / "update.json.sig"
            staged_public = temporary / "public.der"
            staged_manifest.write_bytes(payload)
            staged_public.write_bytes(actual_public)
            openssl("pkeyutl", "-sign", "-rawin", "-inkey", args.private_key,
                    "-in", staged_manifest, "-out", staged_signature)
            signature = staged_signature.read_bytes()
            if len(signature) != 64:
                raise ValueError("Ed25519 signature must contain exactly 64 bytes.")
            openssl("pkeyutl", "-verify", "-rawin", "-pubin", "-keyform", "DER",
                    "-inkey", staged_public, "-in", staged_manifest, "-sigfile", staged_signature)
        (args.packages / "update.json").write_bytes(payload)
        (args.packages / "update.json.sig").write_bytes(signature)
        print(f"Signed updater manifest for {manifest['version']} ({len(manifest['assets'])} assets).")
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        # Never echo command output: key-handling diagnostics may contain secrets.
        parser.exit(1, f"Cannot publish updater manifest: {error}\n")


if __name__ == "__main__":
    main()
