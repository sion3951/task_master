#!/bin/sh
# Native Ubuntu 22.04 builds keep the package's glibc baseline at 2.35.
# GLFW 3.4 is required for the application's content-scale/Wayland APIs.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl git file build-essential clang cmake pkg-config \
    python3 glslang-tools libfreetype6-dev libvulkan-dev libwayland-dev \
    wayland-protocols libxkbcommon-dev libx11-dev libxrandr-dev \
    libxinerama-dev libxcursor-dev libxi-dev libxxf86vm-dev libegl1-mesa-dev \
    libdecor-0-0 libdecor-0-plugin-1-cairo libx11-data xkb-data fontconfig-config \
    patchelf desktop-file-utils dpkg-dev libcap2-bin squashfs-tools zstd
source_dir=build/toolchains/glfw-source
build_dir=build/toolchains/glfw-build
mkdir -p "$source_dir"
git -C "$source_dir" init --quiet
git -C "$source_dir" fetch --depth 1 https://github.com/glfw/glfw.git \
    7b6aead9fb88b3623e3b3725ebb42670cbe4c579
git -C "$source_dir" checkout --detach FETCH_HEAD
cmake -S "$source_dir" -B "$build_dir" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DBUILD_SHARED_LIBS=ON -DGLFW_BUILD_X11=ON -DGLFW_BUILD_WAYLAND=ON \
    -DGLFW_BUILD_DOCS=OFF -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF
cmake --build "$build_dir" --parallel "$(nproc)"
cmake --install "$build_dir"
ldconfig
