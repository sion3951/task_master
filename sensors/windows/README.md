# Windows CPU and GPU sensor service

The main application stays in Odin. This small .NET 8 bridge hosts
LibreHardwareMonitor's CPU and GPU sensor backends as a Windows service. It samples once
per second and serves read-only local named-pipe snapshots, including actual CPU
package watts and per-core clock measurements, plus GPU temperature, package
power, fan percentage and core clocks when the vendor driver exposes them.
It never accepts a request body,
driver command, fan-control setting, MSR address, executable path, or module.
Hardware sampling wakes when a client connects and stops after five seconds
without clients, closing LibreHardwareMonitor's hardware handles. The pipe
listener remains available. An initial cold request gets an unavailable/waking
snapshot immediately; subsequent periodic reads get the newly measured data.
Persistence's once-per-second reads keep hardware collection active.

Build with a .NET 8 SDK:

```powershell
dotnet publish sensors/windows/task_master.Sensors.csproj -c Release -r win-x64 --self-contained true -p:RestoreLockedMode=true -o build/windows/sensors
# Native Windows ARM64:
dotnet publish sensors/windows/task_master.Sensors.csproj -c Release -r win-arm64 --self-contained true -p:RestoreLockedMode=true -o build/windows-arm64/sensors
```

Publishing removes unused .NET assemblies using `TrimMode=copyused`. It retains
every member of assemblies that remain, and explicitly keeps the complete
hardware libraries and Event Log message resources. Built-in COM stays enabled
for WMI. Do not change this to member-level trimming: hardware discovery and
AMD GPU PCI identity use reflection. Debugger support and build symbols are
excluded; `--diagnose` remains available. The linker version is pinned alongside
the package lock file so SDK patch updates do not change locked restores.

Then, from an administrator PowerShell:

```powershell
./scripts/install-sensors.ps1
```

Windows x64 builds bundle the unchanged official PawnIO installer for offline
local setup. ARM64 builds omit this unsupported driver. Remote Install / fix
downloads the matching sensor archive on first use and caches it for reuse;
the x64 archive includes PawnIO. A standalone x64 helper without the bundled
installer downloads it when needed. Driver upgrades reuse one verified
download. Sensor runtime staging uses parallel copies and retains private ACLs,
service rollback and bounded start/stop waits. Setup logs record stage timings.

The installer verifies SHA-256 and Authenticode for the pinned official signed
PawnIO 2.2.0 installer, and installs `task_master_sensors` in a directory writable
only by SYSTEM and Administrators. The desktop and persistence collector do not
need elevation. Existing PawnIO 2.2+ installations are retained. There is no
WinRing0 fallback and no disabled Windows driver-signature checks.

Uninstall the helper with `./scripts/install-sensors.ps1 -Remove`. PawnIO is
shared by other monitoring applications, so it remains installed unless removal
is explicitly requested with `-Remove -RemoveDriver`.

The ABI keeps the 1,444-byte little-endian CPU packet documented in `SensorPacket.cs`
and appends a 1,040-byte GPU extension,
served once per connection on `\\.\pipe\task_master_sensors-v1`. Concurrent
desktop/background clients receive the same immutable snapshot. Processor
indexes flatten active groups in increasing group/logical-processor order.
The public LHM `GenericCpu.CpuId` supplies real group and thread IDs; Intel
hybrid and AMD sparse core numbering are mapped explicitly, without assigning
socket-local physical-core ordinals to global logical IDs.
Old clients read the original CPU prefix; updated clients also accept packets
from old CPU-only services. GPU entries use PCI bus/device identity where
available, otherwise a unique adapter name or the sole adapter of that vendor.
Ambiguous multi-GPU sensor matches remain unavailable. NVIDIA NVML readings
take precedence; AMD and Intel use the helper's measured sensors. Qualcomm
GPU usage and memory come directly from Windows WDDM counters, without
requiring a vendor helper or a vendor sensor SDK.

Power is marked valid only when every detected CPU package reports a value.
Clocks absent on a particular CPU remain unavailable; a nominal/base clock is
never substituted for a measured clock. Sensor access failures carry an error
message. Driver/CPU support is determined by the pinned LHM/PawnIO versions;
no software can provide a sensor that hardware does not expose. The existing
Odin telemetry backend supplies native Windows frequency counters on platforms
without supported hardware sensors.
On Windows ARM64, the desktop, collector and helper run natively; installation
skips the unsupported Intel/AMD kernel driver. The helper reports the sensor limitation
without attempting emulated CPUID or inventing a package-power value.

`task_master.Sensors.exe --diagnose` performs one bounded local sensor diagnostic
and exits. Driver access for that command may require administrator rights.
Normal operation uses only the installed service's snapshot pipe.

Remote sensor archives are `task_master-windows-sensors-amd64.zip` and
`task_master-windows-sensors-arm64.zip`. Each contains only its own architecture's
self-contained runtime at the archive root; the amd64 archive also includes the
official PawnIO installer. `install-sensors.ps1` checks the runtime against the
host architecture before staging its service.
