ODIN ?= odin
GLSLC ?= $(shell command -v glslc 2>/dev/null || command -v glslangValidator 2>/dev/null || echo glslc)
GLSLC_FLAGS ?= $(if $(filter %glslangValidator,$(GLSLC)),-V)
# Keep idle per-thread scratch small; Odin grows it for larger JSON frames and
# releases the additional blocks after each sample/frame.
ODIN_MEMORY_FLAGS := -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
PACKAGE_VERSION ?= $(shell cat VERSION)
ODIN_VERSION_FLAGS := -define:TASK_MASTER_VERSION=$(PACKAGE_VERSION)
TELEMETRY_SOURCES := $(wildcard telemetry*.odin)
COLLECTOR_SOURCES := $(wildcard collector/*.odin)
UPDATE_HELPER_SOURCES := $(wildcard updater_helper/*.odin)
UPDATE_SECURITY_SOURCES := $(wildcard updater_security/*.odin)
# Each desktop embeds only its native collector; remote helpers are fetched on demand.
NATIVE_PAYLOAD_OS := $(shell uname -s | tr A-Z a-z)
ifeq ($(NATIVE_PAYLOAD_OS),darwin)
GRAPHICS_SOURCES := shaders/ui.metal
ODIN_NATIVE_FLAGS := -minimum-os-version:13.0
else
GRAPHICS_SOURCES := shaders/ui.vert.spv shaders/ui.frag.spv
endif
WINDOW_SOURCES := $(wildcard desktop_window/*.odin)
.PHONY: all run clean check collector update-helper collectors windows-check macos-check macos release install install-remote appimage deb packages packages-development
export HOST
all: build/task_master build/task_master-collector build/task_master-update-helper

shaders/ui.vert.spv: shaders/ui.vert
	$(GLSLC) $(GLSLC_FLAGS) $< -o $@

shaders/ui.frag.spv: shaders/ui.frag
	$(GLSLC) $(GLSLC_FLAGS) $< -o $@

build/task_master: $(wildcard *.odin) $(WINDOW_SOURCES) $(UPDATE_SECURITY_SOURCES) VERSION assets/update-public-key.hex scripts/update-install-unix.sh scripts/update-install-windows.ps1 scripts/update-download-windows.ps1 scripts/remote-setup.sh scripts/remote-setup.ps1 scripts/install-system.sh scripts/install-remote-unix.sh scripts/install-remote-windows.ps1 scripts/install-sensors.ps1 sensors/macos/task_master-sensors.sh sensors/macos/sensors.plist $(GRAPHICS_SOURCES) assets/Inter-Regular.ttf build/task_master-collector
	mkdir -p build
	$(ODIN) build . -out:$@ -o:speed -no-bounds-check -vet $(ODIN_MEMORY_FLAGS) $(ODIN_VERSION_FLAGS) $(ODIN_NATIVE_FLAGS)

# Stage just the shared sampler and protocol; the remote agent has no GLFW or
# Vulkan dependency and does not require a display server.
build/task_master-collector: $(TELEMETRY_SOURCES) remote_protocol.odin $(COLLECTOR_SOURCES) VERSION
	mkdir -p build/collector-src
	cp $(TELEMETRY_SOURCES) remote_protocol.odin $(COLLECTOR_SOURCES) build/collector-src/
	$(ODIN) build build/collector-src -out:$@ -o:speed -vet $(ODIN_MEMORY_FLAGS) $(ODIN_VERSION_FLAGS) $(ODIN_NATIVE_FLAGS)

collector: build/task_master-collector

# This protected installer verifies signed metadata again after elevation.
build/task_master-update-helper: $(UPDATE_HELPER_SOURCES) $(UPDATE_SECURITY_SOURCES) VERSION assets/update-public-key.hex scripts/update-install-root.sh
	mkdir -p build
	$(ODIN) build updater_helper -out:$@ -o:speed -vet $(ODIN_MEMORY_FLAGS) $(ODIN_VERSION_FLAGS) $(ODIN_NATIVE_FLAGS)

update-helper: build/task_master-update-helper

# Build or import separately published remote collector assets when requested.
collectors:
	sh scripts/build-collectors.sh $(COLLECTOR_ARGS)

release:
	$(MAKE) -B all

# Typecheck and generate Windows COFF objects without installing or running it.
windows-check: shaders/ui.vert.spv shaders/ui.frag.spv build/task_master-collector
	$(ODIN) build . -target:windows_amd64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/task_master-windows-check.obj
	$(ODIN) build build/collector-src -target:windows_amd64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/collector-windows-check.obj
	$(ODIN) build . -target:windows_arm64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/task_master-windows-arm64-check.obj
	$(ODIN) build build/collector-src -target:windows_arm64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/collector-windows-arm64-check.obj

# Generate both macOS architectures without linking or requiring an Apple SDK.
macos-check: shaders/ui.metal build/task_master-collector
	$(ODIN) build . -target:darwin_arm64 -minimum-os-version:13.0 -build-mode:obj -use-single-module -vet -out:build/task_master-macos-arm64-check.o
	$(ODIN) build . -target:darwin_amd64 -minimum-os-version:13.0 -build-mode:obj -use-single-module -vet -out:build/task_master-macos-amd64-check.o
	$(ODIN) build build/collector-src -target:darwin_arm64 -minimum-os-version:13.0 -build-mode:obj -use-single-module -vet -out:build/collector-macos-arm64-check.o
	$(ODIN) build build/collector-src -target:darwin_amd64 -minimum-os-version:13.0 -build-mode:obj -use-single-module -vet -out:build/collector-macos-amd64-check.o

macos:
	sh scripts/build-macos.sh $(MACOS_ARGS)

# Release packages contain only this machine's native runtime payloads.
appimage: release
	sh scripts/build-appimage.sh $(PACKAGE_ARGS)

deb: release
	sh scripts/build-deb.sh $(PACKAGE_ARGS)

packages: release
	sh scripts/build-appimage.sh $(PACKAGE_ARGS)
	sh scripts/build-deb.sh $(PACKAGE_ARGS)
	cd build/packages && sha256sum *.AppImage *.deb > SHA256SUMS

# Local-development packaging uses the same native-only payloads.
packages-development: all
	sh scripts/build-appimage.sh $(PACKAGE_ARGS)
	sh scripts/build-deb.sh $(PACKAGE_ARGS)

run: all
	./build/task_master

# Authorization belongs to installation. Builds and app launches never prompt.
install: all
	sh scripts/install.sh local

install-remote: build/task_master-collector
	sh scripts/install.sh remote "$$HOST"

check: $(GRAPHICS_SOURCES) build/task_master-collector
	$(ODIN) check . -vet

clean:
	rm -rf build
	rm -f shaders/*.spv
