#!/usr/bin/env python3
"""Reject privileged Linux helper dependencies outside trusted system paths."""
import os
import pathlib
import re
import stat
import subprocess
import sys


def validate(binary):
    # Ignore build-toolchain/AppImage loader overrides when resolving the
    # installed helper's runtime. Its RPATH is removed by the package builder.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("LD_")}
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    output = subprocess.check_output(["ldd", binary], env=environment, text=True)
    if "not found" in output:
        raise SystemExit(f"Missing update-helper runtime library:\n{output}")
    paths = re.findall(r"(?:=>\s+|^\s*)(/\S+)", output, re.MULTILINE)
    paths.append(subprocess.check_output(
        ["patchelf", "--print-interpreter", binary], env=environment, text=True
    ).strip())
    roots = tuple(map(pathlib.Path, ("/lib", "/lib64", "/usr/lib", "/usr/lib64")))
    for value in paths:
        path = pathlib.Path(value).resolve(strict=True)
        if not any(path.is_relative_to(root) for root in roots):
            raise SystemExit(f"Update helper requires a non-system library: {path}")
        for ancestor in (path, *path.parents):
            metadata = ancestor.stat()
            if metadata.st_uid != 0 or metadata.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
                raise SystemExit(f"Update helper library path is writable by a non-root account: {ancestor}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate-update-helper.py ELF_BINARY")
    validate(sys.argv[1])
