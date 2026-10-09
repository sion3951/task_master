#!/usr/bin/env python3
"""Stage matching X11/XKB and Fontconfig data for the AppImage libraries."""
import argparse
import os
import pathlib
import shutil
import stat


def skip(name):
    # Configuration/data are shared; host caches and temporary files are not.
    return (name.startswith((".", "cache", "CACHEDIR.TAG"))
            or name.endswith(("~", ".bak", ".tmp", ".lock", ".cache")))


def rooted_source(source, source_root):
    """Resolve symlinks inside an extracted root without reading host targets."""
    pending = list(source.relative_to(source_root).parts)
    path = source_root
    links = 0
    while pending:
        part = pending.pop(0)
        if part == ".":
            continue
        if part == "..":
            if path == source_root:
                raise SystemExit(f"Runtime data symlink escapes the source root: {source}")
            path = path.parent
            continue
        path = path / part
        if path.is_symlink():
            links += 1
            if links > 40:
                raise SystemExit(f"Runtime data symlink loop: {source}")
            target = pathlib.Path(os.readlink(path))
            if target.is_absolute():
                path = source_root
                pending = list(target.parts[1:]) + pending
            else:
                path = path.parent
                pending = list(target.parts) + pending
    return path


def materialize(source, destination, source_root, ancestors=(), copied_sources=None):
    source = rooted_source(source, source_root)
    if source in ancestors:
        raise SystemExit(f"Directory symlink loop in runtime data: {source}")
    mode = source.stat().st_mode
    if stat.S_ISDIR(mode):
        destination.mkdir(parents=True, exist_ok=True)
        destination.chmod(0o755)
        for child in sorted(source.iterdir()):
            if not skip(child.name):
                materialize(child, destination / child.name, source_root, (*ancestors, source), copied_sources)
    elif stat.S_ISREG(mode):
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o644)
        if copied_sources is not None:
            copied_sources.add(source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("appdir", type=pathlib.Path)
    parser.add_argument("--source-root", type=pathlib.Path, default=pathlib.Path("/"),
                        help="Matching build root or extracted distribution data (default: /)")
    args = parser.parse_args()
    if os.uname().sysname != "Linux":
        raise SystemExit("Stage Linux runtime data on the Linux package build host.")
    share = args.appdir / "usr/share"
    source_root = args.source_root.resolve(strict=True)
    manifest = args.appdir / "usr/lib/task_master/libraries.txt"
    if not manifest.is_file():
        raise SystemExit("Run the AppImage library bundler before staging matching runtime data.")
    sources = (
        (pathlib.Path("/usr/share/X11/locale"), share / "X11/locale",
         "x11-compose-data", pathlib.Path("/usr/share/X11/locale/locale.dir")),
        (pathlib.Path("/usr/share/X11/xkb"), share / "X11/xkb",
         "xkb-keyboard-data", pathlib.Path("/usr/share/X11/xkb/rules/evdev")),
        (pathlib.Path("/etc/fonts"), share / "task_master/fontconfig",
         "fontconfig-configuration", pathlib.Path("/etc/fonts/fonts.conf")),
    )
    fontconfig_sources = set()
    rooted_representatives = {}
    for source, destination, name, representative in sources:
        source = rooted_source(source_root / source.relative_to("/"), source_root)
        representative = rooted_source(source_root / representative.relative_to("/"), source_root)
        if not source.is_dir() or not representative.is_file():
            raise SystemExit(f"Required matching runtime data is missing: {source}. Install libx11-data, xkb-data and fontconfig-config.")
        rooted_representatives[name] = representative
        materialize(source, destination, source_root, copied_sources=fontconfig_sources if name == "fontconfig-configuration" else None)
    configuration = share / "task_master/fontconfig"
    # Keep font locations and the user's font directories intact. Relocate
    # only absolute references to the configuration tree we just bundled.
    for path in configuration.rglob("*"):
        if path.is_file() and path.suffix in (".conf", ".dtd"):
            text = path.read_text()
            text = text.replace(">/etc/fonts/conf.d<", ">conf.d<")
            text = text.replace(">/etc/fonts/conf.avail<", ">conf.avail<")
            path.write_text(text)
    entries = {}
    for line in manifest.read_text().splitlines():
        name, separator, path = line.partition(": ")
        if separator:
            entries[name] = path
    for name, representative in rooted_representatives.items():
        entries[name] = str(representative)
    # Font packages can contribute conf.d symlink targets; preserve their
    # copyright notices alongside the Fontconfig package's own configuration.
    for index, source in enumerate(sorted(fontconfig_sources)):
        entries[f"fontconfig-data/{index:03d}-{source.name}"] = str(source)
    manifest.write_text("\n".join(f"{name}: {source}" for name, source in sorted(entries.items())) + "\n")
    print("Bundled matching X11 compose, XKB keyboard and Fontconfig configuration data.")


if __name__ == "__main__":
    main()
