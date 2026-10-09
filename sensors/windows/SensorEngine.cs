using LibreHardwareMonitor.Hardware;
using LibreHardwareMonitor.Hardware.Cpu;
using LibreHardwareMonitor.PawnIo;

namespace task_master.Sensors;

internal sealed class SensorEngine : IDisposable
{
    private readonly Computer computer = new() { IsCpuEnabled = true };
    private readonly int[] groupBases;
    private readonly uint logicalCount;
    private bool opened;
    private bool permissionDenied;
    private string openError = "";

    public SensorEngine()
    {
        int groups = Native.GetActiveProcessorGroupCount();
        groupBases = new int[groups];
        int count = 0;
        for (ushort group = 0; group < groups; group++)
        {
            groupBases[group] = count;
            count += (int)Native.GetActiveProcessorCount(group);
        }
        logicalCount = (uint)Math.Min(SensorPacket.MaxCpus, count);
    }

    public void Open()
    {
        if (System.Runtime.InteropServices.RuntimeInformation.OSArchitecture !=
            System.Runtime.InteropServices.Architecture.X64)
        {
            openError = "LibreHardwareMonitor/PawnIO CPU sensors require native Intel/AMD x64 hardware. Windows counters remain available.";
            return;
        }
        if (!PawnIo.IsInstalled || PawnIo.Version < new Version(2, 2))
        {
            openError = "Install the signed PawnIO 2.2+ sensor driver with scripts/install-sensors.ps1.";
            return;
        }
        using var driver = Native.OpenSensorDriver();
        if (driver.IsInvalid)
        {
            permissionDenied = System.Runtime.InteropServices.Marshal.GetLastWin32Error() == 5;
            openError = permissionDenied
                ? "Sensor driver access denied. Repair the task_master_sensors service installation."
                : "PawnIO driver is unavailable. Repair its installation or restart Windows.";
            return;
        }
        computer.Open();
        opened = true;
    }

    public SensorPacket Sample()
    {
        var frequencies = new float[SensorPacket.MaxCpus];
        if (!opened)
            return new(logicalCount, 0, false, permissionDenied, frequencies, openError);

        var cpus = computer.Hardware.OfType<GenericCpu>().ToArray();
        float watts = 0;
        bool completePower = cpus.Length > 0;
        foreach (var cpu in cpus)
        {
            cpu.Update();
            var package = cpu.Sensors.FirstOrDefault(sensor => sensor.SensorType == SensorType.Power &&
                (sensor.Name == "CPU Package" || sensor.Name == "Package"));
            if (package?.Value is float power && float.IsFinite(power) && power >= 0)
                watts += power;
            else
                completePower = false;

            if (cpu.CpuId[0][0].Vendor == Vendor.Intel)
            {
                // Intel indexes core clocks from 1, independently of P/E core
                // display names. CpuId contains the exact socket/group/thread.
                for (int core = 0; core < cpu.CpuId.Length; core++)
                {
                    var clock = cpu.Sensors.FirstOrDefault(sensor =>
                        sensor.SensorType == SensorType.Clock && sensor.Index == core + 1);
                    CopyClock(clock, cpu.CpuId[core], frequencies);
                }
            }
            else if (cpu.CpuId[0][0].Vendor == Vendor.AMD &&
                cpu.CpuId[0][0].Family is 0x17 or 0x19 or 0x1a)
            {
                // Match the pinned LHM Amd17Cpu constructor's numbering. Ryzen
                // hardware core IDs can contain holes, so ordinal CoreId/SMT
                // arithmetic is incorrect, especially across sockets/groups.
                int ordinal = 0;
                int previous = -1;
                foreach (var threads in cpu.CpuId.OrderBy(core => core[0].ExtData[0x1e, 1] & 0xff))
                {
                    int hardwareCore = (int)(threads[0].ExtData[0x1e, 1] & 0xff);
                    if (hardwareCore != previous) ordinal++;
                    previous = hardwareCore;
                    var clock = cpu.Sensors.FirstOrDefault(sensor =>
                        sensor.SensorType == SensorType.Clock && sensor.Name == $"Core #{ordinal}");
                    CopyClock(clock, threads, frequencies);
                }
            }
            else
            {
                // Earlier AMD chips use core clock index == CpuId ordinal.
                for (int core = 0; core < cpu.CpuId.Length; core++)
                {
                    var clock = cpu.Sensors.FirstOrDefault(sensor => sensor.SensorType == SensorType.Clock &&
                        sensor.Index == core && sensor.Name.StartsWith("CPU Core", StringComparison.Ordinal));
                    CopyClock(clock, cpu.CpuId[core], frequencies);
                }
            }
        }
        var errors = new List<string>();
        if (!completePower) errors.Add("CPU package power is not exposed by this hardware/driver.");
        if (frequencies.Take((int)logicalCount).Any(clock => clock <= 0))
            errors.Add("Measured clocks are unavailable for some logical CPUs.");
        return new(logicalCount, completePower ? watts : 0, completePower, false, frequencies, string.Join(" ", errors));
    }

    private void CopyClock(ISensor? sensor, CpuId[] threads, float[] result)
    {
        if (sensor?.Value is not float mhz || !float.IsFinite(mhz) || mhz <= 0) return;
        foreach (var thread in threads)
        {
            if (thread.Group < 0 || thread.Group >= groupBases.Length) continue;
            int index = groupBases[thread.Group] + thread.Thread;
            if (index >= 0 && index < logicalCount) result[index] = mhz;
        }
    }

    public void Dispose() => computer.Close();
}
