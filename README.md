# task_master

A native Linux, Windows and macOS system monitor combining the CPU, memory and
process information you would look for in btop with the NVIDIA information you
would look for in nvtop. Written in Odin, rendered directly with Vulkan.

## Version 1.0.1

- Overview, CPU, GPU and Mem+IO dashboards with live graphs and process tables.
- Local and SSH-connected machines in one window, with automatic collector deployment.
- Process grouping, sorting, pinning, PID expansion and process termination.
- Optional background persistence that keeps recent history while the window is closed.
- GPU-rendered graphs, display scaling and Linux X11/Wayland support.

Download installers from this repository's **Releases** page: Linux AppImage or
Debian package (x64/ARM64), Windows x64 setup executable, or macOS package
(Intel/Apple Silicon). Windows 11 ARM64 uses x64 emulation. The `v1.0.1` tag
starts the installer workflow; downloads appear after all builds succeed.
See the [v1.0.1 release notes](docs/releases/v1.0.1.md) for UI fixes and download
details, and the installation sections below for platform requirements.

The application name is exactly `task_master`. Debian uses `task-master` for
its internal package ID, and macOS uses `dev.task-master.desktop` for its bundle
ID because those identifiers prohibit underscores. Executables, installer
filenames, application bundles and displayed names use `task_master`.

## Interface

The interface uses a black background and neutral panels. CPU, GPU, RAM and
VRAM utilisation colours blend from green at 0%, through amber at 50%, to red at 100% on history
lines, busy-time bands, percentages and sibling-thread bars. Physical-core
ranges use their measured lower bound for colour; each history sample retains
its own utilisation colour. RAM and swap details and process CPU/RAM/VRAM values
use the same scale; memory colours show the fraction of capacity used.
The window follows the compositor's assigned size, including Hyprland tiling
and fractional display scaling.
Every history graph has one gentle gradient anchored to its full height and
cut off by the line. Utilisation fills match the green/amber/red colour of a
line at that height; fixed-colour traces retain their hue. Opacity runs from
3% at the bottom to 8% at the top, retaining a faint tint at zero. Fills sit
behind all traces, including RAM series, and stay anchored when scrolled.
In CPU, GPU and Mem+IO, the inspected time appears beside the cursor inside
the hovered graph, switching sides near its edge. A pinned time stays attached
to the graph where it was selected; narrow windows retain the label.

## Build and run

On Linux, requires Odin, GLFW 3.4 or newer, a Vulkan loader/driver, FreeType,
`glslc` (or `glslangValidator`) and `make`.
NVIDIA telemetry additionally requires the driver's `libnvidia-ml.so.1`.

```sh
make
./build/task_master
```

Or use `make run`. The font and shaders are embedded, so the resulting binary
does not need its source directory at runtime.

## Installers and Linux packages

The `Installers` GitHub Actions workflow builds **x64 and ARM64** Linux AppImages
and `.deb` packages, a Windows x64 setup `.exe` (also runs under Windows 11 ARM64
emulation), and native Intel/Apple Silicon macOS `.pkg` installers on `v*` tags
or from **Run workflow**. Manual runs upload downloadable artifacts; tagged runs
attach all installers and a combined `SHA256SUMS` to the GitHub release. It first
builds Linux, Windows and macOS collectors and embeds all six payloads into each desktop, retaining automatic remote deployment.
The compiler, GLFW, AppImage tool/runtime and Actions revisions are pinned.

Release binaries build on Ubuntu 22.04 (glibc 2.35). AppImages bundle FreeType,
GLFW 3.4, the Vulkan loader, X11/Wayland libraries and Cairo window decorations,
with matching keyboard/Compose data and font configuration. The user's system
and personal fonts remain available.
The host provides glibc, the C++ runtime and its GPU drivers/NVML; GPU drivers
are kept together with their matching kernel modules. Building on a newer
distribution raises the minimum runtime version, so use the workflow or an
Ubuntu 22.04 build environment for distribution.

Local release packaging uses the same scripts:

```sh
# Import the six collectors produced by their native build hosts:
make packages COLLECTOR_ARGS="--linux-dir artifacts --windows-dir artifacts --mac-dir artifacts"
# Or build one format:
make appimage COLLECTOR_ARGS="--linux-dir artifacts --windows-dir artifacts --mac-dir artifacts"
make deb COLLECTOR_ARGS="--linux-dir artifacts --windows-dir artifacts --mac-dir artifacts"
```

`build/packages/` contains `task_master-<version>-x86_64.AppImage` or
`task_master-<version>-aarch64.AppImage`, and
`task_master_<version>_amd64.deb` or `task_master_<version>_arm64.deb`.
`VERSION` supplies the local version; override it with
`PACKAGE_ARGS="--version 1.2.3"`. The package scripts accept `--build-dir` and
`--output-dir` when packaging already-built binaries. `make packages-development`
uses whichever remote payloads are currently available and is explicitly a
development build.

AppImage packaging needs Python 3, `patchelf`, and the libraries listed in
`scripts/ci/setup-linux.sh`. Its tool/runtime download is checksum-verified and
cached under `build/toolchains/`. `.deb` assembly also needs `dpkg-dev` on a
matching Debian/Ubuntu build host: dependencies come from the actual ELF symbol
metadata, rather than guesses about the machine that will install it. GLFW is
private to task_master, so an older system GLFW does not remove functionality.
`DEB_MAINTAINER` can supply your distribution maintainer/contact. Bundled-library
notices are included; use `THIRD_PARTY_LICENSE_DIR` for custom dependency notices.

```sh
chmod +x task_master-1.0.1-x86_64.AppImage
./task_master-1.0.1-x86_64.AppImage
# Or install directly from a terminal:
./task_master-1.0.1-x86_64.AppImage --install
# Optional portable launch without installation:
./task_master-1.0.1-x86_64.AppImage --run
# Debian/Ubuntu installs power access as part of package configuration:
sudo apt install ./task_master_1.0.1_amd64.deb
```

Opening the AppImage starts installation and requests administrator authorization.
It installs the bundled runtime in `/opt/task_master`, the `task_master` command,
an applications-menu entry and the power-access collector. The installed app
runs as your normal user and no longer needs the downloaded file or FUSE.
Graphical installation uses host `zenity`/`kdialog` and polkit; a terminal
installer is used when a graphical dialog is unavailable. Install `libcap2-bin`
(or your distribution's `libcap` package) if the installer requests `setcap`.
Remove it with `/opt/task_master/AppRun --remove`, or the original AppImage
with `--remove`; preferences and histories are retained.

AppImages also install or run without FUSE using
`APPIMAGE_EXTRACT_AND_RUN=1 ./task_master-1.0.1-x86_64.AppImage`
(add `--run` for portable use).
OpenSSH and the user's existing keys/configuration remain on the host.
Persistence copies packaged libraries/plugins into its stable per-user runtime,
so it continues after the AppImage unmounts. Neither format enables Persistence
automatically. The `.deb` grants `CAP_PERFMON` only to its root-owned headless
collector at `/usr/libexec/task_master/collector`; the desktop stays unprivileged.
The AppImage installer uses `/usr/local/libexec/task_master/collector`.
`--install-power-access` remains available for installing just that collector.
Capability failures produce installation diagnostics, and package removal retains
user preferences and history. Disable Persistence in the app before uninstalling
if you want its private background sampler to stop as well.

## macOS 13 and newer

The macOS desktop and collector run natively on Apple Silicon and Intel Macs.
The four views, histories, process grouping/PID expansion, sorting, visibility
rules, pinning, pause, SSH discovery/connections, process termination and
persistence share the existing UI. Vulkan rendering runs on the Mac's GPU
through bundled [MoltenVK](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md),
which translates Vulkan to Metal. A separate Vulkan driver installation is
unnecessary on the target machine.

Build on a Mac with [Odin](https://odin-lang.org/docs/install/), Xcode Command
Line Tools, Python 3, `glslc`, FreeType and MoltenVK. Homebrew provides
`shaderc`, `freetype` and `molten-vk`; the Vulkan SDK is another MoltenVK/glslc
source. The build targets macOS 13 explicitly and rejects runtime libraries
whose deployment target is newer. For older target systems, use libraries
built for macOS 13 rather than newer-only Homebrew bottles.

```sh
xcode-select --install
brew install shaderc freetype molten-vk
# A native development bundle embeds whichever remote payloads are present:
sh scripts/build-macos.sh --arch native --development
# Open build/macos-arm64/task_master.app on Apple Silicon, or macos-amd64 on Intel.
```

For a complete release, build the two thin macOS collector payloads independently,
then combine them with the Linux and Windows release inputs:

```sh
sh scripts/build-macos.sh --collector-only
# Import Linux x64/ARM64 and Windows collector artifacts from their build hosts:
sh scripts/build-macos.sh --linux-dir artifacts/linux --windows-dir artifacts/windows
```

The complete build requires all six collector payloads and the Windows build's
`task_master-windows-sensors.zip`, keeping every remote
platform available from either macOS desktop architecture. It produces
`build/macos-amd64/task_master.app` and `build/macos-arm64/task_master.app`.
`FREETYPE_AMD64`, `FREETYPE_ARM64`, `MOLTENVK_AMD64` and `MOLTENVK_ARM64`
accept architecture-specific dylib paths; `FREETYPE_LIBRARY` and
`MOLTENVK_LIBRARY` accept universal libraries. The defaults search the matching
Intel/Apple Silicon Homebrew prefix, plus `VULKAN_SDK` for MoltenVK.
Cross-building a desktop requires dependencies containing that architecture;
the collector-only build needs no FreeType or MoltenVK. Runtime dependencies
are copied as real files, thinned, made relocatable and individually signed
before the app is signed, following Apple's
[bundle/signing layout](https://developer.apple.com/documentation/xcode/embedding-nonstandard-code-structures-in-a-bundle).
Builds use ad-hoc signing by default; set `SIGN_IDENTITY` for your signing
identity. Distribution/notarization is a separate release step. Provide extra
dependency notices with `THIRD_PARTY_LICENSE_DIR` when packaging custom libraries.
`make macos-check` typechecks and generates macOS ARM64/x64 desktop and collector
objects on Linux without executing macOS. It checks source/object compatibility;
native app signing, launchd, Metal rendering and device telemetry require a Mac.

Each full macOS build also produces
`build/packages/task_master-<version>-amd64.pkg` and/or
`build/packages/task_master-<version>-arm64.pkg`. Double-click the matching `.pkg`
to install the complete app, collector and sensor service using macOS Installer.
Pass `--version` to `scripts/build-macos.sh` to override `VERSION`.
Already-built bundles can be packaged with
`sh scripts/build-macos-pkg.sh --arch arm64` (or `amd64`).
`INSTALLER_SIGN_IDENTITY` signs the installer with your Developer ID Installer
certificate; app signing still uses `SIGN_IDENTITY`. Public distribution requires
your Apple signing credentials and notarization.

The command-line installation path remains available:

```sh
sudo sh scripts/install-macos.sh
# Or, inside build/macos-arm64 or build/macos-amd64:
sudo sh install-macos.sh
```

Installation copies the app into `/Applications`, installs the native SSH
collector at `/usr/local/libexec/task_master/collector`, and starts the
`dev.task_master.sensors` LaunchDaemon. The root-owned helper runs Apple's fixed
`powermetrics` sensor command and publishes a read-only atomic snapshot in
`/var/run/task_master/sensors.txt`. Administrator authorization is confined to
installation; the desktop, SSH collector and persistence collector remain
unprivileged. Install the helper on each Mac where CPU/GPU power and measured
clocks are wanted. Hardware/OS combinations expose different sensors; readings
keep their measured/fallback/unavailable status rather than inventing values.

CPU/process/RAM/swap and disk/network sampling use native Mach, libproc,
sysctl and IOKit APIs. Process CPU keeps one core = 100%, RAM keeps RSS
semantics, and physical-core grouping handles Intel SMT and Apple Silicon's
performance/efficiency cores. GPU activity, device allocations and available
power/clocks/thermal/fan readings use IORegistry and the sensor snapshot.
Apple Silicon uses shared system memory: device allocation readings describe
shared GPU allocations, rather than a separate VRAM bank. macOS does not expose
reliable per-process resident GPU-memory bytes; available GPU clients remain
visible while those memory readings show unavailable.

macOS **Persistence** installs `~/Library/LaunchAgents/dev.task_master.persistence.plist`.
It starts at user login and retains saved SSH connections and graph histories
after the window closes, without initializing GLFW/Vulkan. Its executable,
collector and dylibs are copied into a private stable directory under
`~/Library/Application Support/task_master/persistence/`; caches use
`~/Library/Caches/task_master/persistence/`. Refreshes update the stable runtime
after graceful shutdown, and disabling Persistence stops SSH children before
releasing ownership. The user LaunchAgent runs during the logged-in session.
SSH configuration, agents, Include files and jump hosts retain their normal
macOS OpenSSH behaviour. Remove the installed app/helpers with
`sudo sh '/Library/Application Support/task_master/install-macos.sh' --remove`
(or `sudo sh scripts/install-macos.sh --remove` from the source tree);
the invoking user's persistence agent is stopped and user preferences/cache
history are retained.

## Windows 11 and newer

The Windows build keeps the Odin UI and Vulkan rendering, the four views,
process grouping/PID expansion, sorting, pinning, visibility rules, pause,
machine discovery, SSH connections, process termination and persistence.
The desktop runs as your normal user. NVIDIA device telemetry retains the
existing NVML feature set; GPU rendering works with any Vulkan-capable driver.
As on Linux, sensors depend on what the hardware and driver expose.

Build in a Visual Studio x64 Developer PowerShell with Odin, the Vulkan SDK
(`glslc` on PATH), .NET SDK 8 or newer, and vcpkg (`VCPKG_ROOT` set).
Full builds also require Inno Setup 6.3 or newer (`ISCC.exe` on PATH,
in its standard installation directory, or passed with `-InnoSetupCompiler`).
FreeType and GLFW are linked statically. The font and shaders remain embedded.
When `glslc` is unavailable, the pinned vcpkg manifest supplies its shader compiler.
The helper's managed packages and the FreeType dependency baseline are pinned.

First collect the Linux remote samplers, building on Linux x64 and ARM64
(or using the documented cross compiler):

```sh
sh scripts/build-collectors.sh
# On an x64 host with an ARM64 cross compiler:
CC_ARM64=aarch64-linux-gnu-gcc sh scripts/build-collectors.sh --arch arm64
```

Copy `build/task_master-collector-linux-amd64` and
`build/task_master-collector-linux-arm64` into `build/collectors` on the Windows
build machine. The complete desktop build requires both, plus macOS x64/ARM64
collectors in `build/collectors` (or `-MacCollectorDirectory`), preserving
automatic sampling on all three platforms. Build the Windows collector alone with `-CollectorOnly`
when preparing release inputs on a separate machine.

```powershell
.\scripts\build-windows.ps1
# Or supply an existing static MSVC x64 FreeType library:
.\scripts\build-windows.ps1 -FreeTypeLibrary path\to\freetype.lib
.\build\windows\task_master.exe
```

`build/packages/task_master-<version>-windows-x64-setup.exe` is the Windows
installer. Double-click it to install the desktop, collector, Start menu shortcut
and sensor service. Setup requests administrator authorization and registers
an uninstaller in Windows Settings. Pass `-Version` to `build-windows.ps1` to
override `VERSION`; use `scripts/package-windows.ps1` to repackage a built payload.

`build/windows/task_master.exe` is the application executable used internally by
the installer and remains available for development/portable use. The complete
build directory also supports manual installation from Administrator PowerShell:

```powershell
.\install-windows.ps1
```

Installation adds a Start menu shortcut, installs the collector for Windows
SSH sessions and configures **task_master_sensors**, a read-only CPU sensor
service. It samples on demand and closes hardware handles after clients stop
requesting data; it does not keep sampling when the UI and persistence are off.
The pinned official **PawnIO** installer is hash-checked and its
signature verified; its supported signed driver provides CPU sensor access.
Administrative authorization is confined to installation. The desktop and
persistence collector remain unprivileged. A portable desktop can use the
same helper installed separately with `install-sensors.ps1`.

CPU package power and hardware clocks use LibreHardwareMonitor's supported
Intel/AMD sensors. Driver frequency remains a labelled fallback when measured
clocks are unavailable. NVIDIA temperature, power, fans, clocks and board memory
use Windows NVML; WDDM process VRAM comes from Windows GPU performance counters
because NVML cannot supply that reading under WDDM. Unsupported readings show
unavailable rather than zero; aggregate process VRAM is only marked measured
when all contributing readings are known. Windows GPU counters have documented
limitations on some driver/OS combinations and require a check on the target
machine. CPU power is hardware telemetry, not an estimated utilization-to-watts
conversion.

Windows CPU sampling includes all processor groups, subject to the existing
256-logical-CPU display limit. Services are classified through the Service
Control Manager. Process CPU percentages keep one core = 100%, and process RAM
keeps working-set/RSS semantics. The **Kill PID** action checks creation time
and terminates through the same process handle; protected processes report
Windows access errors. Windows RAM legends use **Standby** and **Modified**;
pagefile usage is enumerated from actual pagefiles, not confused with the
commit limit. Queue averages describe runnable queue pressure and are labelled
separately from Linux load averages. Available per-field memory readings remain
visible even when another counter is missing.

Windows **Persistence** registers a private, same-user Task Scheduler task at
user logon. It preserves collection after the window closes, saved-host SSH
connections, cache history, toggle behaviour and executable refresh. It runs
without a display/Vulkan context or elevation; it does not collect after logout.
Files use Windows user directories and private ACLs; cache publication supports
simultaneous readers. Disabling it stops collection gracefully. SSH child
processes belong to a Windows job so jump-host/proxy children also close.

Windows, Linux and macOS desktops can sample Windows, Linux or macOS SSH hosts.
Windows SSH hosts require the Windows OpenSSH server and the same existing
passwordless authentication/trusted host-key setup. Windows SSH configs live in
`%USERPROFILE%/.ssh`; aliases, Include files, agents and jump hosts are retained.
The collector is installed under `%ProgramFiles%/task_master` or deployed into a
private temporary directory and removed after disconnect. CPU sensor access
must be installed on each Windows host where package power is wanted.

The current Odin compiler emits Windows x64 executables. Windows 11 ARM64 uses
x64 emulation for the desktop/collector; Linux ARM64 collectors are native.
The chosen CPU sensor provider supports Intel/AMD x64, so native ARM64 CPU watts
and measured clocks are not provided by it. Other telemetry remains available.
Native Windows ARM64 builds need upstream Odin target support.

For a Linux desktop release embedding all supported collector payloads:

```sh
make release COLLECTOR_ARGS="--linux-dir artifacts --windows-dir artifacts --mac-dir artifacts"
```

`make` remains a native development build; additional payloads already in
`build` are embedded when present. `make windows-check` generates Windows
COFF objects for the desktop and headless collector without executing Windows
or requiring Windows link libraries. Full Windows runtime/device validation
must be performed on Windows; a cross compile is not a hardware validation.

To uninstall, disable Persistence from your ordinary user session first,
then run `install-windows.ps1 -Remove` as Administrator. The sensor installer
also supports `-Remove` alone, and optional `-RemoveDriver` when PawnIO is not
used by other software. User preferences are retained.

## Controls

- The header clock beside Persistence shows local time as **HH:MM:SS** and keeps
  ticking while telemetry is paused.
- Click a top-right navigation label or press **1–4** for Overview, CPU, GPU, Mem+IO.
- Click **Persistence**, just to the left of Overview, to keep sampling Local and
  saved SSH machines after the window closes. It is off by default. Enabling it
  starts a systemd user service and restores its latest 300 seconds of graph
  history when you open the UI. Disabling it stops the service and returns
  sampling to the window. Pause freezes the selected view while the service
  keeps collecting. The toggle turns amber while the service changes in the
  background; the UI remains usable and retains its graph history. Hover over
  the toggle to read a service error.
- Machine names run across the header as space permits; click a name to switch.
  The dropdown holds the rest and the selected machine's connection details.
  Drag a remote tab or dropdown row onto another machine to reorder; hover over
  the dropdown while dragging to reach overflow hosts. The order is saved.
  **Local** stays pinned first. The small **+** (or **Ctrl+N**) opens the SSH machine picker.
  The refresh arrow beside **+** rescans and checks SSH machines in the background.
  **Ctrl+1–9** selects a machine directly (**Ctrl+1** is always Local). **Left/Right**
  arrows and **A/D** cycle through machines, wrapping at either end. These
  shortcuts are suspended while typing in the add-machine dialog.
- Each page has one shared pair of drag controls at the bottom left of its graph
  group. **Max time** sets the visible span from **10–300 seconds**; **Polling**
  sets the collection interval from **0.1–10 seconds**. Drag left or right from
  the current value to change it; clicking does not jump to a track position.
  Values snap to useful steps; hold **Ctrl** to disable snapping. **Right-click**
  either control to reset it (**90 seconds** for Max time, **1 second** for Polling).
  Both settings apply across all pages and machines, including SSH collectors
  and Persistence, and are saved in the user config directory's
  `task_master/graphs.json`. Changing the visible span or polling interval keeps
  recorded history. The full **300 seconds** are retained at every span, with
  room for **3,001 samples** at the fastest polling interval.
  Shorter polling intervals add graph points and redraw more frequently.
  Changing the interval keeps traces connected, including delayed samples;
  actual sampling breaks remain visible.
  Visual smoothing uses elapsed time at faster rates, preserving the established
  one-second appearance; recorded and inspected readings remain unchanged.
- Press **Space** to pause or resume the selected machine. Sampling defaults to
  once per second. Connected machines keep collecting while another machine
  is selected. Graphs use the selected time span: samples enter at the right and move left,
  leaving the unsampled portion empty while history fills.
  Hover lines follow the pointer directly; readouts ease into the nearest recorded
  sample with 140 ms easing for slow movement, increasing smoothly up to 560 ms
  for fast horizontal scrubbing, including core readings, GPU sensors, RAM legends
  and I/O rates. Smoothing returns to 140 ms as the pointer slows or stops.
  Moving again retargets the animation from the displayed values. Clicking
  pins the line and readouts to that sample; they settle on its exact values.
- Click the header **snowflake / Freeze** control, or press **F**, to freeze all
  graph pages and machines together. The control turns blue and the time axes
  show **Frozen**. Switch pages or machines, scroll, hover and pin readings while
  the captured histories stay fixed. Sampling and process tables continue live;
  click again or press **F** for a short, eased slide into the latest history.
  Frozen traces move left as new samples enter from the right; changing axis
  scales transition with them. Catch-up lasts 0.4 seconds, including long freezes.
  Hover over the
  control to see when it was frozen. Machines without samples at freeze time
  show no frozen history until resumed.
- Overview uses the CPU view's unboxed sections, large readouts, faint dividers,
  and smooth CPU, GPU and RAM histories. Graphics details, network and
  storage rates, and the process table follow the same layout. Narrow windows
  stack the sections; scroll over the summaries or headings to move the page,
  and inside the process list to browse its groups.
- The CPU view groups SMT siblings into physical core columns with faint vertical
  dividers. Its unboxed histories and core rows expand to fill taller windows.
  Scroll to see all cores, and hover over the aligned histories to inspect the
  same moment across every graph. Click to pin/unpin it.
- The GPU view uses the same unboxed readouts and aligned, smooth
  histories for utilisation, video memory, power and graphics-clock frequency.
  Power and frequency sit side by side, with frequency shown in MHz using cyan
  traces and an automatically scaled axis. The power axis tops out at the GPU's
  maximum supported power limit reported by NVML. Devices or older collectors
  without that reading retain the automatic scale based on recent power peaks.
  Video memory is plotted in
  GB, with the axis capped at total device memory rounded up to the nearest whole
  GB (32 for a 5090, 24 for a 3090). Hover to inspect a shared
  moment, or click to pin it, including temperature and fan readings. Scroll
  over the graphs to move the view, and inside the GPU process table to browse
  its groups. Taller windows expand the histories and process list.
- Mem+IO uses the same unboxed layout for RAM and swap, with disk read/write
  in the left half and network receive/transmit in the right half. Each I/O pair
  shares an automatically scaled throughput axis.
  I/O summaries show Total bytes and Max rate since persistence was last
  enabled. They reset on enabling, survive window/service restarts, and include
  background sampling beyond the five-minute graph window. Totals integrate
  recorded rates; disconnected intervals are omitted.
  When no swap or pagefile is configured, its graph and summary are hidden and
  the remaining graphs use the freed space.
  RAM is plotted in GB with distinct, fixed colours for used, free, cache,
  buffers and available memory; its legend follows hover/pinning. The ceiling
  covers total RAM using 4, 8, 12, 16, 24, 32, 48, 64 GB and larger steps.
  Hover inspection and click to pin/unpin select the same moment across both
  columns. Memory, disk and network histories survive persistence reloads;
  older caches fill these graphs as new samples arrive.
  Process breakdowns remain in Overview.
- Click **NAME**, **PIDS**, **CPU %**, **RAM** or **VRAM** in a process table to
  sort the full grouped list. Click again to reverse the order; the small arrow
  marks the active column and direction. The selected column and direction are
  saved per view and machine and restored when task_master restarts. Local sorting
  is saved in `$XDG_CONFIG_HOME/task_master/process-sort.json`; remote sorting uses
  a separate file per SSH alias, including its port when specified.
- Click the small **snowflake** beside **PROCESSES** or **GPU PROCESSES** to freeze
  row positions while selecting. CPU, RAM, VRAM and PIDs keep updating. It turns
  blue while positions are held; click again to resume automatic sorting.
  New groups append at the bottom, and exited groups keep a marked slot until
  sorting resumes. Scrolling, PID expansion and row menus remain available;
  clicking a sort column deliberately rebuilds the order.
  Each machine and view keeps its own held positions until released or the app closes.
- Processes with the same name share a row, with summed CPU and RAM usage and
  their sorted PID list in the existing PID column. Lists stay on one line
  until you click the small down arrow to expand the remaining PIDs; click
  again to collapse. GPU rows group actual GPU processes in the same way and
  sum their VRAM. Scroll inside a process table to see all groups.
- Left-click a process row for **Pin / Unpin** and **Kill PID**. Pinned groups
  stay at the top across views, marked with a small blue dot and separated from
  the remaining rows by a small divider. Pins are saved per machine in
  `$XDG_CONFIG_HOME/task_master/process-pins.json`, with a separate file per SSH
  host. All processes are shown, including system services and kernel threads.
  **Kill PID** sends SIGKILL to the selected process; grouped rows open a
  scrollable PID picker. Choose an individual PID or **Kill all** to kill every
  PID listed in that group. Local and SSH actions
  run in the background, check the sampled process identity, and show failures
  in the menu. They use your existing permissions; no privilege prompt is added.
  Click outside the menu or press **Esc** to dismiss it. Right-click has no menu.
- Press **Esc** or **Q** to exit.

CPU process percentages use one logical core = 100%, so a multithreaded process
can exceed 100%. The Overview CPU summary averages across logical threads. The
CPU view also shows physical core busy time: each core is occupied whenever at
least one sibling runs. Per-thread interval counters cannot determine their
exact overlap, so core occupancy is bounded by the busiest sibling and the
capped sum of siblings. The bright busy line curves through the raw lower-bound
readings, in both the total graph and physical core plots. The faint band shares
that exact curved edge and extends to the curved upper bound; interpolation
rounds corners without averaging away spikes or adding peaks and dips.
Package power and active frequency use the same curve interpolation, preserving
their measured samples and gaps where readings are unavailable.
Numeric readouts retain the raw bounds. One fully busy thread
on each two-thread core therefore shows 100% core busy time and 50% logical
thread activity. Busy time is not a measurement of throughput saturation.

CPU frequency uses hardware feedback where available and labels driver-reported
fallbacks. The active mean weights available core frequencies by their busy
time. CPU package power uses Linux powercap energy deltas, including counter
wrap, RAPL perf package-energy counters, or supported CPU hwmon package sensors;
overlapping domains are not added twice. `make install` installs the desktop to
`/usr/local/bin/task_master` and a root-owned collector to
`/usr/local/libexec/task_master/collector`. Installation grants only that collector
`CAP_PERFMON`, without btop's broader filesystem-read capability. Authentication
is part of installation; builds and ordinary launches never prompt.

An unprivileged desktop, including `./build/task_master` and `make run`, uses the
installed helper when direct power access is denied. At startup the helper opens
only package-energy counters, drops its capability, passes the open descriptors
over a private Unix socket, and exits. The app samples those descriptors itself;
there is no helper process running in the background. Rebuilding or cleaning the
development app leaves the installed helper and its capability intact. The UI
and GPU libraries load without privileges. No root UI or changed kernel perf
policy. The optional persistence service runs as your normal user.
A filesystem mounted `nosuid` ignores file capabilities; install on
a normal host filesystem.

RAM usage
uses Linux `MemAvailable`, which includes reclaimable caches. Rates exclude
loopback networking and disk partitions. GPU process VRAM comes directly from
NVML, with duplicate compute/graphics entries counted once per GPU. Group RAM
is the sum of member RSS values, so shared pages can be counted more than once.

## Remote machines

task_master uses one persistent SSH connection per host, your SSH config aliases,
keys, agent and jump hosts. The header shows as many machine names as fit, with
status dots and a small **+**.
The selected machine stays visible; overflow hosts are in the dropdown. Its
connection details include **Remove**, and dropdown rows have **x** to remove a
remote. Local is always the first machine and cannot be moved or removed.

Click **+** (or press **Ctrl+N**) to open **SSH machines**. It lists hosts whose
passwordless SSH login and command execution have succeeded, with telemetry
status and **Install / fix** and **Terminal** actions beside each machine. Click
a machine's name to view it. **Refresh** checks newly available hosts; the list
scrolls when there are more hosts than fit. `--machines` opens this picker at launch.

Candidates come from concrete aliases in `~/.ssh/config` (including Include
files), readable names in `known_hosts` and `known_hosts2`, and saved machine
settings. Every new or restored host must pass a passwordless login check before
it appears or starts telemetry. A config alias or a trusted host key alone does
not qualify. Failed saved hosts retain their settings and can return on a later
refresh. **Remove** dismisses a host across restarts; checking it explicitly in
the picker restores it. An unlisted alias or `user@host` can be entered with
**Check SSH**, which verifies access before adding it.

Up to eight background workers check hosts concurrently using your normal SSH
configuration, keys, agent and jump hosts. Checks use batch mode, existing
host-key trust, no password prompts and an eight-second deadline. Hashed known
hosts cannot reveal destination names; use an SSH config alias or **Check SSH**.
Nonstandard ports belong in SSH config; discovered known-host ports and IPv6
are retained. Each verified host collects independently of the selected tab.

**Install / fix** opens a local terminal, identifies the remote OS/architecture,
transfers the matching bundled collector and installs hardware sensor access.
On Linux it installs `setcap` if needed and grants the root-owned collector
`CAP_PERFMON`. On macOS it installs the collector and Apple's `powermetrics`
sensor LaunchDaemon. On Windows it installs the collector and the existing
sensor service/PawnIO installer; the SSH account must have an administrator
token. Complete releases carry the Windows sensor archive as well as all six
collectors. Development builds report missing payloads in the terminal.

SSH remains passwordless during installation. Linux/macOS administrator
passwords are entered into `sudo` in the terminal. Errors remain visible there;
task_master reconnects after the terminal finishes, restarting persistent SSH
workers even when the background executable is unchanged. Setup stays in a
verification state until fresh telemetry arrives; a timeout shows the actual
connection error instead of reporting installation success. Temporary installation files
are cleaned up. The app itself stays unprivileged. **Terminal** opens an ordinary
interactive passwordless SSH shell for troubleshooting. GPU readings use the
host's existing GPU driver; unavailable hardware sensors retain their status.

The desktop carries its headless samplers. Automatic deployment selects the
remote operating system and CPU architecture, preferring a compatible installed
collector at `/usr/libexec/task_master/collector` for Linux packages,
`/usr/local/libexec/task_master/collector` for source/AppImage and macOS installs, or the
Windows install location. Otherwise it sends the matching embedded sampler
over SSH into a private temporary directory, starts collection, and removes the
directory when the session ends. Linux samplers need a compatible libc
(the current Linux build requires glibc 2.34 or newer); macOS samplers target
macOS 13+, and Windows samplers target Windows 11+.

Existing custom collector paths and display names in `machines.json` are
preserved. A custom collector must match the host and protocol; the picker
uses automatic installed/temporary sampling for new entries. SSH must already
work without a password prompt. Unknown or changed host keys are rejected;
review them with `ssh server` in your own terminal before checking the host.

The collector needs no display, GLFW or Vulkan. It reads the same `/proc` and
NVML data as Local and runs only for the SSH session, exiting when stdin closes.
NVIDIA data requires the host's NVML driver library; unavailable sensors retain
the existing unavailable display. Package-power permissions are configured as
part of installation on each machine:

```sh
make install
make install-remote HOST=annie-arch
make install-remote HOST=server-arch
```

The installation command authenticates with the host's normal sudo prompt, atomically
installs a root-owned collector with only `CAP_PERFMON`, and prints a one-second
power sample. Restart task_master to open the installed power counters.
The collector drops its capability before loading NVML and runs only for the
SSH session. Repeat the installation after updating collector code; incompatible
protocol versions automatically use the embedded sampler until reinstalled.
An absent installation leaves all other telemetry available. Ports and jump
hosts continue to use your SSH config.

The CPU graph reports permission failures explicitly; hover over the power
graph for the installation command. `--stats` includes the selected source and exact
failure. Remote snapshots carry the same diagnostics.
The temporary sampler is removed on disconnect; no service or listening port is added.
Before the first sample, a failed connection shows its actual error instead of
an empty dashboard. After a disconnect, the last sample stays visible with its age.

The selected view stays the same when switching machines. Each machine has its
own histories, sorting, scroll positions, pause state and pinned processes.
Saved remote machines and configured
SSH aliases start collecting at launch; newly verified hosts start as soon as
discovery finds them, without needing to select their tabs.
A paused remote freezes the displayed
snapshot while its collector continues sampling. Other connected hosts remain
live. A lost connection retains the last readings, marks them stale, and retries
with backoff up to 30 seconds. SSH reads and decoding run on one background CPU
worker per remote; all drawing stays on the local Vulkan GPU. With Persistence
off, closing task_master or removing a machine closes its session and joins its
worker. With Persistence on, the user service owns saved-machine connections
and notices additions, removals and collector changes in the saved machine
list. Temporary `--remote` connections remain attached to the window.

The window shows its fresh local hardware reading immediately; cached history
loads on the background reader. Local sampling continues during service startup
until a current snapshot includes the GPUs detected by the desktop, preventing
an older cache from replacing live GPU readings with an unavailable state.
Fresh history stays connected across the desktop/service handoff and a short
service refresh at launch, including remote SSH sampler handoffs; longer outages,
explicit pauses and dropped samples retain their gaps. Remote graphs start with
the first measured interval, avoiding the collector's startup CPU dip.

On Linux, Persistence requires a running systemd user manager; Windows uses a
user Task Scheduler task and macOS uses a user LaunchAgent. Its enablement is remembered
and it starts with your user session; enabling it does not change logout or
lingering policy. The service follows the selected polling interval without
opening a window or initializing Vulkan. It retains every sample, while a
background publisher writes caches at most once per second so serialization
and disk I/O do not block fast sampling. A separate lightweight live publisher
and reader update graphs at the selected polling interval, independently of
those larger history saves. Cached readings are private to your
user, updated atomically, and bounded to 300 seconds / 3,001 samples per machine. The UI reports
service errors and stale telemetry. It uses the existing SSH trust, authentication,
retry behavior and each platform's native GPU sampling.

The Linux user unit is `$XDG_CONFIG_HOME/systemd/user/task_master-persistence.service`.
Enabling it copies the executable to
`$XDG_DATA_HOME/task_master/persistence/bin/task_master`, so cleaning a development
build does not stop background sampling. History lives in
`$XDG_CACHE_HOME/task_master/persistence/`. Normal XDG defaults apply.
When persistence is enabled, launching an updated app refreshes its background
executable and restarts the service on a worker. Unchanged executables keep the
running service. GPU utilization, VRAM usage, power, graphics-clock frequency,
temperature and fan readings, RAM (including free, cache and buffers), swap,
disk read/write and network
receive/transmit rates are retained with each history sample.
For terminal control, use `./build/task_master --persistence=on` or
`./build/task_master --persistence=off`. The on command also updates an already
enabled service.

Machine order, manual hosts and dismissed discovered hosts are saved in
`$XDG_CONFIG_HOME/task_master/machines.json` (normally
`~/.config/task_master/machines.json`). Remote process preferences use a separate
file per SSH alias; Local keeps its established preference file. For a temporary
connection, use `./build/task_master --remote=server`; this does not save the host.

## Lightweight design

- Native telemetry APIs (`/proc`/NVML on Linux, Windows APIs, Mach/libproc/IOKit
  on macOS), with no web runtime. The privileged macOS hardware sensor helper
  invokes Apple's `powermetrics`; process/system sampling stays in-process.
- Bounded process buffers and CPU process counters grow with the workload and
  reuse their storage between samples, retaining the full 16,384 system-PID and
  2,048 GPU-PID limits. Display snapshots start at approximately 52 KiB instead
  of reserving approximately 2.4 MiB for maximum-size process tables on every host.
  Remote snapshots use versioned newline-delimited JSON with a 16 MiB frame limit;
  JSON decoding memory is reclaimed after every snapshot. SSH frame storage starts
  at 64 KiB and grows with incoming data, retaining the same 16 MiB limit.
  Thread scratch starts at 64 KiB, grows when required and releases additional
  blocks after each sample/frame. Process groups occupy 120 bytes.
- One hinted FreeType font atlas, rasterized at the actual display density, and
  one persistent Vulkan vertex buffer, allocated on demand from 256 KiB and
  growing as needed for dense graph histories. CPU vertex storage also grows
  with geometry; both release excess capacity after 120 smaller frames.
  Font raster storage grows with the glyphs, and the texture uses its actual
  occupied height. Glyphs and panel edges align to
  physical pixels; a monitor density change rebuilds the atlas once.
- One GPU draw per frame; GLFW sleeps between samples and wakes for input/resize.
- Compatible Vulkan drivers save native pipeline binaries under
  `$XDG_CACHE_HOME/task_master/pipelines/` (normally
  `~/.cache/task_master/pipelines/`). Later launches restore the binaries without
  creating shader modules or compiling the UI shaders again. Driver/device and
  pipeline keys invalidate incompatible data, including changed shaders or
  pipeline settings. Missing, corrupt or rejected files are rebuilt atomically;
  drivers without the required features use the existing SPIR-V compilation
  path. Binary files are private to your user and bounded to 8 MiB per surface
  format. `--startup-profile` reports compilation/saving or binary loading.
  Reusing binaries avoids compilation work but does not guarantee unloading
  NVIDIA's compiler libraries or reducing resident RAM.
- Persistence service changes and SSH cleanup run on background workers. Cache
  reads and JSON decoding use a background reader, which skips unchanged files
  and transfers the latest update per machine without retaining a duplicate
  worker snapshot. Publication histories grow to their sample count, paused
  publications release their payload, and the reader retains one fleet-wide
  spare. The UI copies completed
  readings and merges graph histories through the change in sampling ownership.
  Once the service takes over local sampling, the desktop unloads its duplicate
  NVML telemetry driver while Vulkan continues rendering. Turning persistence
  off reloads local GPU telemetry while retaining CPU power descriptors.
- Graph lines use analytic GPU antialiasing in physical pixels, with round caps;
  the hinted text atlas and pixel-aligned UI rectangles retain crisp rendering.
- No continuous animation or 60 FPS rendering loop. Process tables reuse their
  sorted rows and PID wrapping between samples, including while scrolling or
  hovering; changes to sorting, pins, expansion, machine, width or DPI
  refresh the cache. Frozen tables retain their cache while live sampling continues.
- Remote updates copy populated display data, preserving local sampler ownership.
  Persistence JSON scratch memory is released per machine rather than accumulating
  across a fleet; atomic cache publication streams through a 16 KiB buffer.
  GPU process deduplication uses sorting and linear reductions,
  retaining maximum VRAM per PID within a GPU and summed VRAM across GPUs.
- Startup prepares telemetry and rasterizes the font on two short-lived CPU
  workers while the main thread initializes GLFW and Vulkan. Both workers finish
  before the first draw; power access is dropped before either worker starts.

On this machine (9800X3D / RTX 5090), the release binary is approximately 2.1 MiB.
The startup pass measured first-frame submission at 194 ms before and 171–178 ms
after overlapping telemetry and font preparation (one baseline and two changed
build runs on the same machine, approximately 8–12% faster). GLFW and Vulkan driver initialization still
account for most startup time. An unpaused four-second
run at the default interval used approximately 0.5% of one CPU core between
startup and shutdown. The October 9 memory pass, with persistence, Local and two
live SSH machines, measured the window at approximately 181 MiB RSS / 60 MiB PSS
and the service at 41 MiB RSS / 30 MiB PSS. Combined RSS fell from approximately
275 to 222 MiB, and combined proportional memory from 141 to 89 MiB (about 19%
and 37% respectively). The window still includes approximately 139 MiB of shared
pages, predominantly NVIDIA's Vulkan libraries. Measurements were taken during
four-second runs with full graph histories at 1280x720 and 1.5x display scale;
they are observations, not a guaranteed memory budget. A bounds-checked sanity
run exercised both full PID limits, CPU-counter growth, snapshot roundtripping,
display copies and rejection of invalid frames. NVML unloading/reloading was
also checked on the real GPU. PNG capture is more expensive than normal
monitoring and is excluded from the CPU figure.

## Diagnostics

```sh
./build/task_master --stats
./build/task_master-collector --stats
./build/task_master --smoke
./build/task_master --smoke --startup-profile
./build/task_master --capture=build/prototype.png
./build/task_master --view=cpu --capture=build/cpu.png
./build/task_master --view=mem+disk --capture=build/memory-disk.png
```

`--stats` samples once without opening a window. `--smoke` opens the app for
four seconds and exits. `--startup-profile` prints elapsed time for each startup
stage; worker stages overlap the main thread and should not be summed.
`--capture` saves an actual Vulkan-rendered PNG after
three seconds, then exits; compression can extend the total run time.

Version 1.0.1 displays the first NVIDIA device in summary graphs, collects up
to eight GPUs, 256 logical cores, 16,384 system PIDs and 2,048 GPU PIDs.
Process tables sort and scroll through all collected groups.
Non-NVIDIA GPU telemetry is not implemented yet. A missing device or unsupported
GPU sensor displays an unavailable state.

Files: `main.odin` (dashboard and input), `process_ui.odin` (grouped process tables),
`process_preferences.odin` (saved pins, sorting and row menus),
`process_actions.odin` (background local and SSH PID controls),
`cpu_ui.odin` (physical CPU graphs), `gpu_ui.odin` (GPU dashboard),
`memory_ui.odin` (RAM, swap and disk graphs),
`overview_ui.odin` (Overview dashboard),
`telemetry.odin` (live system data),
`renderer.odin` (Vulkan/GLFW), `machines.odin` (host selector and saved state),
`remote_connection.odin` (SSH workers), `ssh_discovery.odin` (host candidates),
`persistence.odin` (user service and graph cache),
`persistence_toggle.odin` (background service changes),
`persistence_reader.odin` (background cache decoding),
`ssh_login.odin` (passwordless login checks),
`remote_protocol.odin` (telemetry snapshots),
`collector/main.odin` (headless sampler), `shaders/` (GPU program),
`assets/` (font and licence).
Use `make clean` to remove build outputs.
