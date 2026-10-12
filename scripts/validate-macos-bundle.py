#!/usr/bin/env python3
"""Verify a macOS 13 app links only Apple-supplied runtime dependencies."""
import pathlib
import re
import subprocess
import sys


def tool(name, *args):
    return subprocess.check_output(["xcrun", name, *map(str, args)], text=True)


def validate_binary(path, architecture):
    tool("lipo", path, "-verify_arch", architecture)
    output = tool("otool", "-arch", architecture, "-l", path)
    deployment_commands = 0
    for block in re.split(r"Load command \d+", output):
        if "LC_BUILD_VERSION" not in block and "LC_VERSION_MIN_MACOSX" not in block:
            continue
        deployment_commands += 1
        found = re.search(r"\b(?:minos|version) (\d+)\.(\d+)(?:\.(\d+))?", block)
        if not found:
            raise SystemExit(f"Cannot determine the deployment target of {path}.")
        version = tuple(int(part or 0) for part in found.groups())
        if version > (13, 0, 0):
            raise SystemExit(f"{path} requires macOS {'.'.join(map(str, version))}; build for macOS 13.")
    if not deployment_commands:
        raise SystemExit(f"Missing macOS deployment target in {path}.")
    for line in tool("otool", "-arch", architecture, "-L", path).splitlines()[1:]:
        dependency = line.strip().split(" (compatibility version", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Unexpected non-system dependency in {path}: {dependency}")


def main():
    if len(sys.argv) != 3 or sys.argv[2] not in ("x86_64", "arm64"):
        raise SystemExit("Usage: validate-macos-bundle.py APP_BUNDLE x86_64|arm64")
    bundle = pathlib.Path(sys.argv[1])
    for executable in ("task_master", "task_master-collector", "task_master-update-helper"):
        validate_binary(bundle / "Contents/MacOS" / executable, sys.argv[2])


if __name__ == "__main__":
    main()
