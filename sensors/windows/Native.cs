using System.ComponentModel;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace task_master.Sensors;

internal static class Native
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public uint Length;
        public IntPtr Descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }

    [DllImport("kernel32.dll")] public static extern ulong GetTickCount64();
    [DllImport("kernel32.dll")] public static extern ushort GetActiveProcessorGroupCount();
    [DllImport("kernel32.dll")] public static extern uint GetActiveProcessorCount(ushort group);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle CreateNamedPipeW(string name, uint openMode, uint pipeMode,
        uint maxInstances, uint outputSize, uint inputSize, uint timeout, ref SecurityAttributes attributes);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string descriptor, uint revision, out IntPtr result, IntPtr size);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint sharing,
        IntPtr attributes, uint disposition, uint flags, IntPtr template);

    public static SafeFileHandle OpenSensorDriver() => CreateFileW(@"\\?\GLOBALROOT\Device\PawnIO",
        0xc0000000, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);

    public static NamedPipeServerStream CreateSnapshotPipe(bool first)
    {
        // Authenticated local users may only read. Only SYSTEM/Administrators
        // can create instances/write; PIPE_REJECT_REMOTE_CLIENTS denies SMB.
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GR;;;AU)", 1, out var descriptor, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            var attributes = new SecurityAttributes
            {
                Length = (uint)Marshal.SizeOf<SecurityAttributes>(), Descriptor = descriptor, Inherit = false
            };
            var handle = CreateNamedPipeW(@"\\.\pipe\task_master_sensors-v1",
                2u | 0x40000000u | (first ? 0x00080000u : 0), // outbound, overlapped, first instance
                0x8, 16, SensorPacket.Size, 0, 1000, ref attributes);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error);
            }
            return new NamedPipeServerStream(PipeDirection.Out, true, false, handle);
        }
        finally { LocalFree(descriptor); }
    }
}
