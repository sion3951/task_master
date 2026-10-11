using LibreHardwareMonitor.Hardware;
using LibreHardwareMonitor.Hardware.Cpu;
using LibreHardwareMonitor.Hardware.Gpu;
using LibreHardwareMonitor.PawnIo;

namespace task_master.Sensors;

internal sealed class SensorEngine : IDisposable
{
    private readonly Computer computer = new() { IsCpuEnabled = true, IsGpuEnabled = true };
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
            computer.IsCpuEnabled = false;
        }
        if (computer.IsCpuEnabled && (!PawnIo.IsInstalled || PawnIo.Version < new Version(2, 2)))
        {
            openError = "Install the signed PawnIO 2.2+ sensor driver with scripts/install-sensors.ps1.";
            computer.IsCpuEnabled = false;
        }
        using var driver = Native.OpenSensorDriver();
        if (computer.IsCpuEnabled && driver.IsInvalid)
        {
            permissionDenied = System.Runtime.InteropServices.Marshal.GetLastWin32Error() == 5;
            openError = permissionDenied
                ? "Sensor driver access denied. Repair the task_master_sensors service installation."
                : "PawnIO driver is unavailable. Repair its installation or restart Windows.";
            computer.IsCpuEnabled = false;
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
        if (openError.Length > 0) errors.Add(openError);
        else if (!completePower) errors.Add("CPU package power is not exposed by this hardware/driver.");
        if (frequencies.Take((int)logicalCount).Any(clock => clock <= 0))
            errors.Add("Measured clocks are unavailable for some logical CPUs.");
        return new(logicalCount, completePower ? watts : 0, completePower, permissionDenied, frequencies,
            string.Join(" ", errors), SampleGpus());
    }

    private GpuSensor[] SampleGpus()
    {
        var result = new List<GpuSensor>();
        foreach (var gpu in computer.Hardware.OfType<GenericGpu>().Take(SensorPacket.MaxGpus))
        {
            // One failing vendor API must not discard the CPU snapshot or the
            // other cards. The desktop's Windows counters remain independent.
            try
            {
                gpu.Update();
                uint vendor = gpu.HardwareType switch
                {
                    HardwareType.GpuAmd => 0x1002u,
                    HardwareType.GpuIntel => 0x8086u,
                    HardwareType.GpuNvidia => 0x10deu,
                    _ => 0u
                };
                float Read(SensorType type, params string[] names)
                {
                    foreach (string name in names)
                    {
                        var sensor = gpu.Sensors.FirstOrDefault(s => s.SensorType == type && s.Name == name);
                        if (sensor?.Value is float value && float.IsFinite(value) && value >= 0) return value;
                    }
                    return float.NaN;
                }
                float temperature = Read(SensorType.Temperature, "GPU Core");
                float power = Read(SensorType.Power, "GPU Package", "GPU Power", "GPU PPT");
                float fan = Read(SensorType.Control, "GPU Fan");
                float clock = Read(SensorType.Clock, "GPU Core");
                uint flags = (float.IsFinite(temperature) && temperature <= 200 ? 1u : 0u) |
                    (float.IsFinite(power) ? 2u : 0u) |
                    (float.IsFinite(fan) && fan <= 100 ? 4u : 0u) |
                    (float.IsFinite(clock) && clock > 0 ? 8u : 0u);
                // AMD exposes PCI bus/device as public properties on its
                // internal class. No vendor enum order is used as identity.
                int PciProperty(string name) => gpu.GetType().GetProperty(name)?.GetValue(gpu) switch
                {
                    int value => value,
                    uint value when value <= int.MaxValue => (int)value,
                    _ => -1
                };
                result.Add(new(gpu.Name, vendor, PciProperty("BusNumber"), PciProperty("DeviceNumber"),
                    flags, temperature, power, fan, clock));
            }
            catch { }
        }
        return result.ToArray();
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
