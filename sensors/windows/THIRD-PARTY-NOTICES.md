# Sensor bridge dependencies

* **LibreHardwareMonitorLib 0.9.6**, MPL-2.0, copyright LibreHardwareMonitor and
  contributors. Unmodified NuGet dependency with pinned package lock file.
  Source: https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/tree/v0.9.6
  Package: https://www.nuget.org/packages/LibreHardwareMonitorLib/0.9.6
  License: `licenses/LibreHardwareMonitor-MPL-2.0.txt`.
  LHM incorporates hardware modules under their own licenses; preserve the
  upstream package's license notices when redistributing.
* **PawnIO 2.2.0** official signed driver, copyright namazso and contributors.
  The installer is downloaded unchanged rather than embedded in task_master.
  Official download: https://pawnio.eu
  Pinned binary: https://github.com/namazso/PawnIO.Setup/releases/tag/2.2.0
  Driver source/license: https://github.com/namazso/PawnIO
  License: GPL-2.0-or-later with the upstream independent-device-IO-module
  exception, included in `licenses/PawnIO-notice.txt`.
  Signed module source: https://github.com/namazso/PawnIO.Modules
* **System.ServiceProcess.ServiceController 8.0.1** and .NET runtime, MIT,
  copyright .NET Foundation and contributors.
  https://github.com/dotnet/runtime/tree/v8.0.1
  License: `licenses/dotnet-MIT.txt`.
* **BlackSharp.Core 1.0.7**, **DiskInfoToolkit 1.1.2**, and
  **RAMSPDToolkit-NDD 1.4.2**, MPL-2.0, copyright Florian K.
  Sources: https://github.com/Blacktempel/BlackSharp,
  https://github.com/Blacktempel/DiskInfoToolkit,
  https://github.com/Blacktempel/RAMSPDToolkit.
  License: `licenses/LibreHardwareMonitor-MPL-2.0.txt` (same MPL-2.0 text).
* **HidSharp 2.6.4**, Apache-2.0, copyright 2010-2025 James F. Bellinger.
  Source: https://github.com/IntergatedCircuits/HidSharp
  License and notice copied unchanged from the pinned package:
  `licenses/HidSharp-Apache-2.0.txt`.
* **Mono.Posix.NETStandard 1.0.0**, copyright Microsoft Corporation.
  Upstream source and license: https://github.com/mono/mono
  License collection: `licenses/Mono-LICENSE.txt`.
* **System.CodeDom 10.0.2**, **System.Diagnostics.EventLog 8.0.1**,
  **System.IO.Ports 10.0.3**, **System.Management 10.0.2**, and
  **System.Threading.AccessControl 10.0.3**, MIT, copyright .NET Foundation
  and contributors. Source: https://github.com/dotnet/runtime.
  License: `licenses/dotnet-MIT.txt`.

All transitive managed dependency versions/content hashes are recorded in
`packages.lock.json`. Their package licenses remain applicable; publishing
copies the original dependency assemblies unchanged. The main application
neither links the sensor bridge nor the driver directly.
