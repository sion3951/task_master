ODIN ?= odin
GLSLC ?= $(shell command -v glslc 2>/dev/null || command -v glslangValidator 2>/dev/null || echo glslc)
GLSLC_FLAGS ?= $(if $(filter %glslangValidator,$(GLSLC)),-V)
# Keep idle per-thread scratch small; Odin grows it for larger JSON frames and
# releases the additional blocks after each sample/frame.
ODIN_MEMORY_FLAGS := -define:DEFAULT_TEMP_ALLOCATOR_BACKING_SIZE=65536
TELEMETRY_SOURCES := $(wildcard telemetry*.odin)
COLLECTOR_SOURCES := $(wildcard collector/*.odin)
# Embed available extra payloads in development builds. The release target
# requires the complete set, so a Windows desktop also retains Linux remotes.
NATIVE_PAYLOAD_OS := $(shell uname -s | tr A-Z a-z)
NATIVE_PAYLOAD_ARCH := $(shell uname -m | sed -e s/x86_64/amd64/ -e s/aarch64/arm64/)
EXTRA_PAYLOADS := $(wildcard build/task_master-windows-sensors.zip build/task_master-collector-linux-amd64 build/task_master-collector-linux-arm64 build/task_master-collector-linux-riscv64 build/task_master-collector-windows-amd64 build/task_master-collector-windows-arm64 build/task_master-collector-darwin-amd64 build/task_master-collector-darwin-arm64)
REMOTE_PAYLOAD_FLAGS := $(foreach arch,$(filter-out $(if $(filter linux,$(NATIVE_PAYLOAD_OS)),$(NATIVE_PAYLOAD_ARCH)),amd64 arm64 riscv64),$(if $(wildcard build/task_master-collector-linux-$(arch)),-define:TASK_MASTER_COLLECTOR_LINUX_$(shell echo $(arch) | tr a-z A-Z)=build/task_master-collector-linux-$(arch)))
REMOTE_PAYLOAD_FLAGS += $(foreach arch,amd64 arm64,$(if $(wildcard build/task_master-collector-windows-$(arch)),-define:TASK_MASTER_COLLECTOR_WINDOWS_$(shell echo $(arch) | tr a-z A-Z)=build/task_master-collector-windows-$(arch)))

REMOTE_PAYLOAD_FLAGS += $(foreach arch,amd64 arm64,$(if $(wildcard build/task_master-collector-darwin-$(arch)),-define:TASK_MASTER_COLLECTOR_DARWIN_$(shell echo $(arch) | tr a-z A-Z)=build/task_master-collector-darwin-$(arch)))

REMOTE_PAYLOAD_FLAGS += $(if $(wildcard build/task_master-windows-sensors.zip),-define:TASK_MASTER_WINDOWS_SENSORS=build/task_master-windows-sensors.zip)

.PHONY: all run clean check collector collectors windows-check macos-check macos release install install-remote appimage deb packages packages-development
export HOST
all: build/task_master build/task_master-collector

shaders/ui.vert.spv: shaders/ui.vert
	$(GLSLC) $(GLSLC_FLAGS) $< -o $@

shaders/ui.frag.spv: shaders/ui.frag
	$(GLSLC) $(GLSLC_FLAGS) $< -o $@

build/task_master: $(wildcard *.odin) scripts/remote-setup.sh scripts/remote-setup.ps1 scripts/install-system.sh scripts/install-remote-unix.sh scripts/install-remote-windows.ps1 scripts/install-sensors.ps1 sensors/macos/task_master-sensors.sh sensors/macos/sensors.plist shaders/ui.vert.spv shaders/ui.frag.spv assets/DejaVuSans.ttf build/task_master-collector $(EXTRA_PAYLOADS)
	mkdir -p build
	$(ODIN) build . -out:$@ -o:speed -no-bounds-check -vet $(ODIN_MEMORY_FLAGS) $(REMOTE_PAYLOAD_FLAGS)

# Stage just the shared sampler and protocol; the remote agent has no GLFW or
# Vulkan dependency and does not require a display server.
build/task_master-collector: $(TELEMETRY_SOURCES) remote_protocol.odin $(COLLECTOR_SOURCES)
	mkdir -p build/collector-src
	cp $(TELEMETRY_SOURCES) remote_protocol.odin $(COLLECTOR_SOURCES) build/collector-src/
	$(ODIN) build build/collector-src -out:$@ -o:speed -vet $(ODIN_MEMORY_FLAGS)

collector: build/task_master-collector

# Build this host's collector and import Windows artifacts when supplied.
# For a complete release, require every target payload before embedding.
collectors:
	sh scripts/build-collectors.sh $(COLLECTOR_ARGS)

release:
	sh scripts/build-collectors.sh --all $(COLLECTOR_ARGS)
	$(MAKE) -B build/task_master

# Typecheck and generate Windows COFF objects without installing or running it.
windows-check: shaders/ui.vert.spv shaders/ui.frag.spv build/task_master-collector
	$(ODIN) build . -target:windows_amd64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/task_master-windows-check.obj
	$(ODIN) build build/collector-src -target:windows_amd64 -windows-sdk-root:/tmp -linker:lld -build-mode:obj -use-single-module -vet -out:build/collector-windows-check.obj

# Generate both macOS architectures without linking or requiring an Apple SDK.
macos-check: shaders/ui.vert.spv shaders/ui.frag.spv build/task_master-collector
	$(ODIN) build . -target:darwin_arm64 -build-mode:obj -use-single-module -vet -out:build/task_master-macos-arm64-check.o
	$(ODIN) build . -target:darwin_amd64 -build-mode:obj -use-single-module -vet -out:build/task_master-macos-amd64-check.o
	$(ODIN) build build/collector-src -target:darwin_arm64 -build-mode:obj -use-single-module -vet -out:build/collector-macos-arm64-check.o
	$(ODIN) build build/collector-src -target:darwin_amd64 -build-mode:obj -use-single-module -vet -out:build/collector-macos-amd64-check.o

macos:
	sh scripts/build-macos.sh $(MACOS_ARGS)

# Release packages retain every remote OS/architecture. Import collector
# artifacts through COLLECTOR_ARGS as for the existing release target.
appimage: release
	sh scripts/build-appimage.sh $(PACKAGE_ARGS)

deb: release
	sh scripts/build-deb.sh $(PACKAGE_ARGS)

packages: release
	sh scripts/build-appimage.sh $(PACKAGE_ARGS)
	sh scripts/build-deb.sh $(PACKAGE_ARGS)
	cd build/packages && sha256sum *.AppImage *.deb > SHA256SUMS

# Explicit local-development packaging uses the payloads already present.
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

check: shaders/ui.vert.spv shaders/ui.frag.spv build/task_master-collector
	$(ODIN) check . -vet

clean:
	rm -rf build
	rm -f shaders/*.spv
