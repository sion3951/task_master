#!/usr/bin/env python3
"""Bundle libdecor's Cairo window decorations and their native dependencies."""
import argparse
import os
import pathlib
import re
import shutil
import subprocess


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(binary):
    found = {}
    for line in run("ldd", str(binary)).splitlines():
        if "=> not found" in line:
            raise SystemExit(f"Missing decoration dependency of {binary}: {line.strip()}")
        match = re.match(r"\s*(\S+) => (/\S+) ", line)
        if match:
            found[pathlib.Path(match[1]).name] = pathlib.Path(match[2]).resolve()
    return found


def excluded(name):
    # Match the main AppImage bundler's host glibc/GPU-driver policy.
    return (re.match(r"lib(?:c|m|pthread|rt|dl|util|resolv|nss_\w+|anl)\.so", name)
            or name.startswith(("ld-linux", "ld-musl", "libstdc++", "libgcc_s", "libnvidia", "libcuda", "libGLX_nvidia",
                                "libvulkan_radeon", "libvulkan_intel")))


def elf_identity(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) != 20 or header[:4] != b"\x7fELF":
        return None
    # ELF class, byte order and e_machine identify the target architecture.
    return header[4:6], header[18:20]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library_directory", type=pathlib.Path)
    args = parser.parse_args()
    if os.uname().sysname != "Linux":
        raise SystemExit("Bundle Linux decorations on Linux.")
    for tool in ("ldd", "patchelf"):
        if not shutil.which(tool):
            raise SystemExit(f"Required tool not found: {tool}")
    library_directory = args.library_directory
    libdecor = library_directory / "libdecor-0.so.0"
    manifest = library_directory / "libraries.txt"
    if not libdecor.is_file() or not manifest.is_file():
        raise SystemExit("Stage libdecor-0.so.0 with bundle-linux-libraries.py before bundling its plugin.")
    sources = {}
    for line in manifest.read_text().splitlines():
        name, separator, path = line.partition(": ")
        if separator:
            sources[name] = pathlib.Path(path)
    libdecor_source = sources.get("libdecor-0.so.0")
    if libdecor_source is None or not libdecor_source.is_file():
        raise SystemExit("The libdecor source path is missing from libraries.txt.")
    plugin_source = libdecor_source.parent / "libdecor/plugins-1/libdecor-cairo.so"
    if not plugin_source.is_file():
        raise SystemExit("Install libdecor's Cairo plugin (Ubuntu: libdecor-0-plugin-1-cairo) before packaging.")
    if elf_identity(plugin_source) != elf_identity(libdecor):
        raise SystemExit(f"Decoration plugin architecture does not match bundled libdecor: {plugin_source}")

    # Cairo supplies client-side frames even when the Wayland compositor has no
    # server-side decoration protocol, without bringing GTK and its modules in.
    plugin_relative = pathlib.Path("libdecor/plugins-1/libdecor-cairo.so")
    plugin_target = library_directory / plugin_relative
    plugin_target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(plugin_source, plugin_target)
    plugin_target.chmod(0o755)
    run("patchelf", "--set-rpath", "$ORIGIN/../..", str(plugin_target))
    sources[str(plugin_relative)] = plugin_source.resolve()
    pending = dependencies(plugin_source)
    examined = set()
    added = 0
    while pending:
        name, source = pending.popitem()
        if name in examined or excluded(name):
            continue
        examined.add(name)
        if elf_identity(source) != elf_identity(libdecor):
            raise SystemExit(f"Decoration dependency has the wrong architecture: {source}")
        target = library_directory / name
        if not target.is_file():
            shutil.copyfile(source, target)
            target.chmod(0o755)
            run("patchelf", "--set-rpath", "$ORIGIN", str(target))
            sources[name] = source
            added += 1
        for child, path in dependencies(source).items():
            if child not in examined:
                pending[child] = path
    manifest.write_text("\n".join(f"{name}: {source}" for name, source in sorted(sources.items())) + "\n")
    print(f"Bundled Cairo window decorations and {added} additional libraries; LIBDECOR_PLUGIN_DIR=<LIBDIR>/libdecor/plugins-1")


if __name__ == "__main__":
    main()
