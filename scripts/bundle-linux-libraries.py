#!/usr/bin/env python3
"""Stage native ELF dependencies with private RUNPATHs, never GPU drivers/glibc."""
import argparse
import ctypes
import os
import pathlib
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(binary):
    found = {}
    output = run("ldd", str(binary))
    for line in output.splitlines():
        if "=> not found" in line:
            raise SystemExit(f"Missing runtime dependency of {binary}: {line.strip()}")
        match = re.match(r"\s*(\S+) => (/\S+) ", line)
        if match:
            found[pathlib.Path(match[1]).name] = pathlib.Path(match[2]).resolve()
    return found


def excluded(name):
    # The host owns its ELF loader, glibc and GPU driver/ICD stack. Mixing a
    # driver with a different kernel module can break graphics and telemetry.
    return (re.match(r"lib(?:c|m|pthread|rt|dl|util|resolv|nss_\w+|anl)\.so", name)
            or name.startswith(("ld-linux", "ld-musl", "libstdc++", "libgcc_s", "libnvidia", "libcuda", "libGLX_nvidia", "libvulkan_radeon", "libvulkan_intel")))


def elf_identity(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) != 20 or header[:4] != b"\x7fELF":
        return None
    return header[4:6], header[18:20]


def locate(name, cache):
    for candidate in cache.get(name, []):
        if candidate.is_file() and elf_identity(candidate) == elf_identity(args.binary):
            return candidate.resolve()
    raise SystemExit(f"Missing dynamically loaded library {name}; install its development/runtime package before building.")


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary", type=pathlib.Path)
parser.add_argument("destination", type=pathlib.Path)
parser.add_argument("library_directory", type=pathlib.Path)
parser.add_argument("--only", help="Copy only this direct dependency (Debian's private GLFW)")
args = parser.parse_args()
if os.uname().sysname != "Linux":
    raise SystemExit("Build Linux packages on Linux.")
for tool in ("ldd", "patchelf"):
    if not shutil.which(tool):
        raise SystemExit(f"Required tool not found: {tool}")
direct = dependencies(args.binary)
if "libglfw.so.3" not in direct:
    raise SystemExit("Desktop does not link the expected GLFW shared library.")
glfw = ctypes.CDLL(str(direct["libglfw.so.3"]))
major, minor, patch = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
glfw.glfwGetVersion(ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch))
if (major.value, minor.value) < (3, 4):
    raise SystemExit("task_master requires GLFW 3.4 or newer; build that library before packaging.")
args.destination.parent.mkdir(parents=True, exist_ok=True)
args.library_directory.mkdir(parents=True, exist_ok=True)
shutil.copyfile(args.binary, args.destination)
args.destination.chmod(0o755)
relative = os.path.relpath(args.library_directory, args.destination.parent)
run("patchelf", "--set-rpath", f"$ORIGIN/{relative}", str(args.destination))
pending = {args.only: direct[args.only]} if args.only else dict(direct)
if not args.only:
    # GLFW loads these at runtime, so they are absent from DT_NEEDED/ldd. Both
    # desktop backends and the Vulkan loader remain available in the AppImage.
    cache = {}
    ldconfig = shutil.which("ldconfig") or "/sbin/ldconfig"
    for line in run(ldconfig, "-p").splitlines():
        match = re.match(r"\s*(\S+) \(.*\) => (/\S+)", line)
        if match:
            cache.setdefault(match[1], []).append(pathlib.Path(match[2]))
    for name in ("libvulkan.so.1", "libwayland-client.so.0", "libwayland-cursor.so.0", "libwayland-egl.so.1", "libxkbcommon.so.0", "libdecor-0.so.0",
                 "libX11.so.6", "libX11-xcb.so.1", "libXrandr.so.2", "libXinerama.so.1", "libXcursor.so.1", "libXi.so.6", "libXxf86vm.so.1"):
        pending[name] = locate(name, cache)
copied = {}
while pending:
    name, source = pending.popitem()
    if excluded(name) or name in copied:
        continue
    target = args.library_directory / name
    shutil.copyfile(source, target)
    target.chmod(0o755)
    copied[name] = source
    run("patchelf", "--set-rpath", "$ORIGIN", str(target))
    if not args.only:
        for child, path in dependencies(source).items():
            if child not in copied:
                pending[child] = path
manifest = args.library_directory / "libraries.txt"
manifest.write_text("\n".join(f"{name}: {source}" for name, source in sorted(copied.items())) + "\n")
print(f"Bundled {len(copied)} libraries; GLFW {major.value}.{minor.value}.{patch.value}; RUNPATH $ORIGIN/{relative}")
