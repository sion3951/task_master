using System.Buffers.Binary;
using System.Text;

namespace task_master.Sensors;

internal sealed record SensorPacket(uint CoreCount, float PowerWatts, bool PowerValid,
    bool PermissionDenied, float[] Frequencies, string Error)
{
    public const int MaxCpus = 256;
    public const int Size = 1444;

    // Version 1: fixed, little-endian, packed ABI shared with telemetry_windows.odin.
    // Offsets: magic 0, version 4, uptime 8, power 16, flags 20,
    // logical count 24, reserved 28, MHz[256] 32, UTF-8 error[384] 1056,
    // error byte length 1440. Zero MHz means unavailable, never base clock.
    public byte[] Encode()
    {
        var result = new byte[Size];
        BinaryPrimitives.WriteUInt32LittleEndian(result, 0x544d5753);
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt64LittleEndian(result.AsSpan(8), Native.GetTickCount64());
        BinaryPrimitives.WriteSingleLittleEndian(result.AsSpan(16), PowerWatts);
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(20),
            (PowerValid ? 1u : 0u) | (PermissionDenied ? 2u : 0u));
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(24), CoreCount);
        for (int i = 0; i < Math.Min(MaxCpus, Frequencies.Length); i++)
            BinaryPrimitives.WriteSingleLittleEndian(result.AsSpan(32 + i * 4), Frequencies[i]);
        // Encoder.Convert never splits a UTF-8 character at the packet boundary.
        Encoding.UTF8.GetEncoder().Convert(Error.AsSpan(), result.AsSpan(1056, 384), true,
            out _, out int bytesUsed, out _);
        BinaryPrimitives.WriteUInt32LittleEndian(result.AsSpan(1440), (uint)bytesUsed);
        return result;
    }
}
