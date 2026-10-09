# Windows CPU sensor service

The main application stays in Odin. This small .NET 8 bridge hosts
LibreHardwareMonitor's CPU sensor backend as a Windows service. It samples once
per second and serves read-only local named-pipe snapshots, including actual CPU
package watts and per-core clock measurements. It never accepts a request body,
driver command, fan-control setting, MSR address, executable path, or module.
Hardware sampling wakes when a client connects and stops after five seconds
without clients, closing LibreHardwareMonitor's hardware handles. The pipe
listener remains available. An initial cold request gets an unavailable/waking
snapshot immediately; subsequent periodic reads get the newly measured data.
Persistence's once-per-second reads keep hardware collection active.

Build with a .NET 8 SDK:

```powershell
dotnet publish sensors/windows/task_master.Sensors.csproj -c Release -r win-x64 --self-contained true -p:RestoreLockedMode=true -o build/windows/sensors
```

Then, from an administrator PowerShell:

```powershell
./scripts/install-sensors.ps1
```

The installer verifies SHA-256 and Authenticode for the pinned official signed
PawnIO 2.2.0 installer, and installs `task_master_sensors` in a directory writable
only by SYSTEM and Administrators. The desktop and persistence collector do not
need elevation. Existing PawnIO 2.2+ installations are retained. There is no
WinRing0 fallback and no disabled Windows driver-signature checks.

Uninstall the helper with `./scripts/install-sensors.ps1 -Remove`. PawnIO is
shared by other monitoring applications, so it remains installed unless removal
is explicitly requested with `-Remove -RemoveDriver`.

The ABI is the 1,444-byte little-endian packet documented in `SensorPacket.cs`,
served once per connection on `\\.\pipe\task_master_sensors-v1`. Concurrent
desktop/background clients receive the same immutable snapshot. Processor
indexes flatten active groups in increasing group/logical-processor order.
The public LHM `GenericCpu.CpuId` supplies real group and thread IDs; Intel
hybrid and AMD sparse core numbering are mapped explicitly, without assigning
socket-local physical-core ordinals to global logical IDs.

Power is marked valid only when every detected CPU package reports a value.
Clocks absent on a particular CPU remain unavailable; a nominal/base clock is
never substituted for a measured clock. Sensor access failures carry an error
message. Driver/CPU support is determined by the pinned LHM/PawnIO versions;
no software can provide a sensor that hardware does not expose. The existing
Odin telemetry backend supplies native Windows frequency counters on platforms
without supported hardware sensors.
On Windows ARM64, the x64 desktop runs through emulation and installation skips
the unsupported x64 kernel driver. The helper reports the sensor limitation
without attempting emulated CPUID or inventing a package-power value.

`task_master.Sensors.exe --diagnose` performs one bounded local sensor diagnostic
and exits. Driver access for that command may require administrator rights.
Normal operation uses only the installed service's snapshot pipe.
