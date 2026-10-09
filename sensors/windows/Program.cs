using System.ServiceProcess;

namespace task_master.Sensors;

internal static class Program
{
    public static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
        {
            Console.Error.WriteLine("task_master sensors require Windows 11 or later.");
            return 1;
        }
        if (args.SequenceEqual(new[] { "--service" }))
        {
            ServiceBase.Run(new SensorsService());
            return 0;
        }
        // An explicit diagnostic invocation is bounded; ordinary users never start
        // a privileged process from the desktop app.
        if (args.SequenceEqual(new[] { "--diagnose" }))
        {
            using var engine = new SensorEngine();
            engine.Open();
            Thread.Sleep(1100);
            var sample = engine.Sample();
            Console.WriteLine($"Logical CPUs: {sample.CoreCount}; package power: {(sample.PowerValid ? sample.PowerWatts : float.NaN)} W");
            Console.WriteLine(sample.Error.Length == 0 ? "Sensors ready." : sample.Error);
            return sample.PowerValid ? 0 : 2;
        }
        Console.Error.WriteLine("Install with scripts/install-sensors.ps1. Options: --service, --diagnose");
        return 1;
    }
}

internal sealed class SensorsService : ServiceBase
{
    private CancellationTokenSource? stop;
    private SensorHost? host;
    private Task? run;

    public SensorsService()
    {
        ServiceName = "task_master_sensors";
        CanStop = true;
        CanShutdown = true;
        AutoLog = true;
    }

    protected override void OnStart(string[] args)
    {
        stop = new CancellationTokenSource();
        // Claim the first pipe instance synchronously; fail service startup if
        // another process already owns this public endpoint.
        host = new SensorHost();
        run = host.RunAsync(stop.Token);
    }

    protected override void OnStop()
    {
        stop?.Cancel();
        try { run?.GetAwaiter().GetResult(); }
        catch (OperationCanceledException) { }
        finally { host?.Dispose(); stop?.Dispose(); }
    }

    protected override void OnShutdown() => OnStop();
}
