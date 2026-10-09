#!/usr/bin/env python3
"""Copy installed-package license notices for libraries staged by the bundler."""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys


def command(*args):
    environment = dict(os.environ, LC_ALL="C")
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env=environment)
    return result.stdout.strip() if result.returncode == 0 else ""


def aliases(source):
    """dpkg metadata can retain /lib paths after merged-/usr migrations."""
    result = [str(source), str(source.resolve())]
    for name in list(result):
        if name.startswith("/usr/lib/"):
            result.append(name[4:])
        elif name.startswith("/lib/"):
            result.append("/usr" + name)
        elif name.startswith("/usr/lib64/"):
            result.append(name[4:])
        elif name.startswith("/lib64/"):
            result.append("/usr" + name)
    return list(dict.fromkeys(result))


def owners(source):
    if shutil.which("dpkg-query"):
        for candidate in aliases(source):
            output = command("dpkg-query", "-S", candidate)
            packages = set()
            for line in output.splitlines():
                if ": " not in line:
                    continue
                names, filename = line.split(": ", 1)
                if filename != candidate:
                    continue
                packages.update(name.strip() for name in names.split(","))
            if packages:
                return "debian", sorted(packages)
    if shutil.which("pacman"):
        for candidate in aliases(source):
            packages = command("pacman", "-Qoq", candidate).splitlines()
            if packages:
                return "arch", packages
    return "", []


def package_notices(manager, package):
    if manager == "debian":
        copyright_file = pathlib.Path("/usr/share/doc") / package.split(":", 1)[0] / "copyright"
        return [copyright_file] if copyright_file.is_file() else []
    notices = []
    directory = pathlib.Path("/usr/share/licenses") / package
    if directory.is_dir():
        notices.extend(sorted(path for path in directory.rglob("*") if path.is_file()))
    # Arch packages using standard licenses can refer to common notices rather
    # than installing another copy under their own package name.
    metadata = command("pacman", "-Qi", package)
    match = re.search(r"^Licenses\s*:\s*(.+)$", metadata, re.MULTILINE)
    if match:
        for license_name in match[1].split():
            spdx = pathlib.Path("/usr/share/licenses/spdx") / (license_name + ".txt")
            if spdx.is_file():
                notices.append(spdx)
            common = pathlib.Path("/usr/share/licenses/common") / license_name
            if common.is_dir():
                notices.extend(sorted(path for path in common.rglob("*") if path.is_file()))
    return list(dict.fromkeys(notices))


def copy_notice(source, destination):
    if source.stat().st_size > 4 * 1024 * 1024:
        raise SystemExit(f"Refusing unusually large license notice: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o644)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("library_directory", type=pathlib.Path)
parser.add_argument("documentation_directory", type=pathlib.Path)
args = parser.parse_args()
manifest = args.library_directory / "libraries.txt"
if not manifest.is_file():
    raise SystemExit(f"Missing bundled-library source manifest: {manifest}")
repository = pathlib.Path(__file__).resolve().parent.parent
destination = args.documentation_directory
destination.mkdir(parents=True, exist_ok=True)
copy_notice(repository / "assets/FONT-LICENSE.txt", destination / "FONT-LICENSE.txt")
copy_notice(repository / "packaging/linux/GLFW-LICENSE.txt", destination / "GLFW-LICENSE.txt")
copied_packages = {}
inventory = []
missing = []
for line in manifest.read_text().splitlines():
    if not line.strip():
        continue
    if ": " not in line:
        raise SystemExit(f"Malformed bundled-library source line: {line}")
    name, original = line.split(": ", 1)
    source = pathlib.Path(original)
    manager, packages = owners(source)
    copied = []
    for package in packages:
        key = manager, package
        if key not in copied_packages:
            notices = package_notices(manager, package)
            if len(notices) > 256:
                raise SystemExit(f"Package {package} contains more than 256 license notices")
            paths = []
            for index, notice in enumerate(notices):
                safe_name = re.sub(r"[^A-Za-z0-9_.+-]", "_", package)
                target = destination / "libraries" / safe_name / f"{index + 1:02d}-{notice.name}"
                copy_notice(notice, target)
                paths.append(str(target.relative_to(destination)))
            copied_packages[key] = paths
        copied.extend(copied_packages[key])
    if name == "libglfw.so.3":
        copied.append("GLFW-LICENSE.txt")
    if not copied:
        missing.append(name)
        print(f"Warning: no installed-package license notice found for {name} ({source}). "
              "Provide its notice in THIRD_PARTY_LICENSE_DIR before distributing the package.", file=sys.stderr)
    inventory.append(f"{name}: {', '.join(copied) if copied else 'NOTICE REQUIRED'}")
extra = os.environ.get("THIRD_PARTY_LICENSE_DIR")
if extra:
    extra_directory = pathlib.Path(extra)
    if not extra_directory.is_dir():
        raise SystemExit(f"THIRD_PARTY_LICENSE_DIR is not a directory: {extra_directory}")
    extra_files = sorted(path for path in extra_directory.rglob("*") if path.is_file())
    if len(extra_files) > 256:
        raise SystemExit("THIRD_PARTY_LICENSE_DIR contains more than 256 files")
    for notice in extra_files:
        copy_notice(notice, destination / "extra" / notice.relative_to(extra_directory))
    inventory.append(f"Additional supplied notices: {len(extra_files)} files in extra/")
(destination / "LIBRARY-NOTICES.txt").write_text("\n".join(inventory) + "\n")
if missing:
    print(f"Warning: inspect LIBRARY-NOTICES.txt and supply notices for {len(missing)} libraries.", file=sys.stderr)
