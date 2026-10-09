using System.IO.Pipes;

namespace task_master.Sensors;

internal sealed class SensorHost : IDisposable
{
    private readonly List<NamedPipeServerStream> pipes = new();
    private readonly SemaphoreSlim wake = new(0, 1);
    private readonly uint logicalCount = Math.Min(SensorPacket.MaxCpus, Native.GetActiveProcessorCount(0xffff));
    private long lastClient;
    private byte[] snapshot = new SensorPacket(0, 0, false, false,
        new float[SensorPacket.MaxCpus], "Sensor service is starting.").Encode();

    public SensorHost()
    {
        try
        {
            for (int i = 0; i < 8; i++) pipes.Add(Native.CreateSnapshotPipe(i == 0));
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public async Task RunAsync(CancellationToken stop)
    {
        // No command parser, writes, driver handles, or controls cross this pipe.
        // Multiple concurrent clients share one immutable snapshot per second.
        var tasks = new List<Task> { Task.Run(() => SampleAsync(stop), stop) };
        tasks.AddRange(pipes.Select(pipe => ServeAsync(pipe, stop)));
        await Task.WhenAll(tasks);
    }

    private async Task SampleAsync(CancellationToken stop)
    {
        SensorEngine? engine = null;
        try
        {
            while (!stop.IsCancellationRequested)
            {
                if (!HasRecentClient())
                {
                    engine?.Dispose();
                    engine = null;
                    Volatile.Write(ref snapshot, IdleSnapshot());
                    await wake.WaitAsync(stop);
                    continue;
                }
                try
                {
                    if (engine == null)
                    {
                        engine = new SensorEngine();
                        engine.Open();
                    }
                    Volatile.Write(ref snapshot, engine.Sample().Encode());
                }
                catch (Exception error)
                {
                    engine?.Dispose();
                    engine = null;
                    Volatile.Write(ref snapshot, new SensorPacket(logicalCount, 0, false,
                        error is UnauthorizedAccessException, new float[SensorPacket.MaxCpus],
                        $"Sensor sampling failed: {error.Message}").Encode());
                    await Task.Delay(9000, stop);
                }
                await Task.Delay(1000, stop);
            }
        }
        finally { engine?.Dispose(); }
    }

    private bool HasRecentClient()
    {
        long last = Volatile.Read(ref lastClient);
        return last != 0 && Native.GetTickCount64() - (ulong)last <= 5000;
    }

    private byte[] IdleSnapshot() => new SensorPacket(logicalCount, 0, false, false,
        new float[SensorPacket.MaxCpus], "Hardware sensors are waking; Windows counters remain available.").Encode();

    private void RecordClient()
    {
        Volatile.Write(ref lastClient, (long)Native.GetTickCount64());
        if (wake.CurrentCount == 0)
        {
            try { wake.Release(); }
            catch (SemaphoreFullException) { }
        }
    }

    private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken stop)
    {
        using (pipe)
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    await pipe.WaitForConnectionAsync(stop);
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
                    timeout.CancelAfter(2000);
                    // A cold request gets an honest unavailable packet promptly.
                    // Never put a fresh timestamp on stale package-power data.
                    await pipe.WriteAsync(HasRecentClient() ? Volatile.Read(ref snapshot) : IdleSnapshot(), timeout.Token);
                    await pipe.FlushAsync(timeout.Token);
                    RecordClient();
                }
                catch (OperationCanceledException) when (stop.IsCancellationRequested) { return; }
                catch (OperationCanceledException) { }
                catch (IOException) { }
                finally { if (pipe.IsConnected) pipe.Disconnect(); }
            }
        }
    }

    public void Dispose()
    {
        foreach (var pipe in pipes) pipe.Dispose();
        wake.Dispose();
    }
}
