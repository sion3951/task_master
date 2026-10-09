#!/usr/bin/env python3
"""Fetch immutable, checksum-pinned official AppImage tool/runtime releases."""
import hashlib
import os
import pathlib
import sys
import urllib.request

PINS = {
    "x86_64": ("ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0",
               "2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"),
    "aarch64": ("f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158",
                "00cbdfcf917cc6c0ff6d3347d59e0ca1f7f45a6df1a428a0d6d8a78664d87444"),
}
directory = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build/toolchains/appimage")
arch = {"arm64": "aarch64"}.get(os.uname().machine, os.uname().machine)
if arch not in PINS:
    raise SystemExit(f"No pinned AppImage runtime for {arch}")
directory.mkdir(parents=True, exist_ok=True)
for name, repo, release, checksum in (
    (f"appimagetool-{arch}.AppImage", "appimagetool", "1.9.1", PINS[arch][0]),
    (f"runtime-{arch}", "type2-runtime", "20251108", PINS[arch][1]),
):
    path = directory / name
    if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
        url = f"https://github.com/AppImage/{repo}/releases/download/{release}/{name}"
        with urllib.request.urlopen(url, timeout=60) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != checksum:
            raise SystemExit(f"Checksum mismatch for {url}")
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_bytes(data)
        temporary.chmod(0o755)
        temporary.replace(path)
    print(path)
