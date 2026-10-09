#!/usr/bin/env python3
"""Stage real, thin, relocatable runtime dylibs using Apple's native tools."""
import pathlib
import re
import shutil
import subprocess
import sys


def tool(name, *args):
    return subprocess.check_output(["xcrun", name, *map(str, args)], text=True).strip()


def fail(message):
    raise SystemExit(message)


def minimum_version(path):
    output = tool("otool", "-arch", architecture, "-l", path)
    # Only minos and LC_VERSION_MIN_MACOSX's version describe deployment.
    blocks = re.split(r"Load command \d+", output)
    for block in blocks:
        if "LC_BUILD_VERSION" in block or "LC_VERSION_MIN_MACOSX" in block:
            found = re.search(r"\b(?:minos|version) (\d+)\.(\d+)(?:\.(\d+))?", block)
            if found and tuple(int(part or 0) for part in found.groups()) > (13, 0, 0):
                fail(f"{path} requires macOS {found.group(0)}; provide a library built for macOS 13.")


def dependencies(path):
    return [line.strip().split(" (compatibility version", 1)[0]
            for line in tool("otool", "-arch", architecture, "-L", path).splitlines()[1:]]


bundle, architecture, freetype, moltenvk, identity = sys.argv[1:]
bundle = pathlib.Path(bundle).resolve()
executable = bundle / "Contents/MacOS/task_master"
frameworks = bundle / "Contents/Frameworks"
search_directories = {pathlib.Path(freetype).resolve().parent, pathlib.Path(moltenvk).resolve().parent}
sources = {}
staged = {}


def expand(reference, source):
    return reference.replace("@loader_path", str(source.parent)).replace("@executable_path", str(executable.parent))


def resolve(reference, source):
    if reference.startswith("@rpath/"):
        relative = reference[len("@rpath/"):]
        output = tool("otool", "-arch", architecture, "-l", source)
        roots = [expand(match, source) for match in re.findall(r"\bpath (.+?) \(offset \d+\)", output)]
        candidates = [pathlib.Path(root) / relative for root in roots]
        candidates.extend(directory / relative for directory in search_directories | {source.parent})
    else:
        candidates = [pathlib.Path(expand(reference, source))]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    fail(f"Cannot resolve {reference} used by {source}; package every non-system runtime dependency.")


def stage_library(source, name=None):
    source = pathlib.Path(source).resolve()
    name = name or source.name
    target = frameworks / name
    if name in sources:
        if sources[name] != source and sources[name].read_bytes() != source.read_bytes():
            fail(f"Conflicting runtime libraries named {name}: {sources[name]} and {source}")
        return target
    sources[name] = source
    search_directories.add(source.parent)
    architectures = tool("lipo", "-archs", source).split()
    if architecture not in architectures:
        fail(f"{source} has no {architecture} slice.")
    if len(architectures) > 1:
        tool("lipo", source, "-thin", architecture, "-output", target)
    else:
        shutil.copyfile(source, target)
    target.chmod(0o755)
    minimum_version(target)
    tool("install_name_tool", "-id", f"@rpath/{name}", target)
    staged[target] = source
    rewrite(target, source)
    return target


def rewrite(target, source):
    for reference in dependencies(source):
        if reference.startswith(("/usr/lib/", "/System/Library/")):
            continue
        # A dylib's first LC_ID_DYLIB entry is its own identity, not a dependency.
        if target.parent == frameworks and resolve(reference, source) == source:
            continue
        dependency_source = resolve(reference, source)
        dependency = stage_library(dependency_source)
        prefix = "@loader_path/" if target.parent == frameworks else "@executable_path/../Frameworks/"
        tool("install_name_tool", "-change", reference, prefix + dependency.name, target)


minimum_version(executable)
stage_library(moltenvk, "libMoltenVK.dylib")
stage_library(freetype)
rewrite(executable, executable)
for library in staged:
    tool("codesign", "--force", "--sign", identity, library)
# build-macos.sh signs the collector and complete app after writing Info.plist.
# Signing the main executable here makes codesign traverse the unfinished bundle.
