using System.Runtime.InteropServices;
using System.Text;

namespace Playtest;

// Windows shared microphone capture. No driver installation, device-default changes or controller hooks.
internal sealed class Recorder : IDisposable
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct Caps { public ushort Mid, Pid; public uint Version; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name; public uint Formats; public ushort Channels, Reserved; }
    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    struct Format { public ushort Tag, Channels; public uint Rate, BytesPerSecond; public ushort Align, Bits, Extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct Header { public IntPtr Data; public uint Length, Recorded; public UIntPtr User; public uint Flags, Loops; public IntPtr Next; public UIntPtr Reserved; }
    [DllImport("winmm.dll")] static extern uint waveInGetNumDevs();
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern uint waveInGetDevCapsW(UIntPtr id, out Caps caps, uint size);
    [DllImport("winmm.dll")] static extern uint waveInOpen(out IntPtr handle, uint id, ref Format format, IntPtr callback, IntPtr instance, uint flags);
    [DllImport("winmm.dll")] static extern uint waveInPrepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInUnprepareHeader(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInAddBuffer(IntPtr handle, IntPtr header, uint size);
    [DllImport("winmm.dll")] static extern uint waveInStart(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInReset(IntPtr handle);
    [DllImport("winmm.dll")] static extern uint waveInClose(IntPtr handle);
    public static List<string> Devices()
    {
        var list = new List<string>();
        for (uint i = 0; i < waveInGetNumDevs(); i++)
        { Check(waveInGetDevCapsW((UIntPtr)i, out var caps, (uint)Marshal.SizeOf<Caps>())); list.Add(caps.Name); }
        return list;
    }
    static void Check(uint code) { if (code != 0) throw new Exception("Microphone capture failed (Windows code " + code + "). Select the headset microphone and check Windows microphone access."); }
    readonly List<(IntPtr Header, IntPtr Data)> buffers = [];
    readonly uint headerSize = (uint)Marshal.SizeOf<Header>();
    readonly Session session;
    SessionLease lease;
    IntPtr handle;
    BinaryWriter writer;
    int bytes;
    long totalSamples;
    int nextBuffer;
    double start;
    long lastBuffer = Environment.TickCount64;
    public float Level { get; private set; }
    public Recorder(Session session, string microphone)
    {
        this.session = session;
        var devices = Devices();
        if (devices.Count(x => x == microphone) != 1) throw new Exception("Select one unambiguous microphone in the desktop window. No automatic device fallback is used.");
        var fmt = new Format { Tag = 1, Channels = 1, Rate = 48000, BytesPerSecond = 96000, Align = 2, Bits = 16 };
        try
        {
            lease = new SessionLease(session.Folder);
            Check(waveInOpen(out handle, (uint)devices.IndexOf(microphone), ref fmt, IntPtr.Zero, IntPtr.Zero, 0));
            for (int i = 0; i < 8; i++)
            {
                IntPtr data = Marshal.AllocHGlobal(24000), hdr = Marshal.AllocHGlobal((int)headerSize);
                buffers.Add((hdr, data));
                Marshal.StructureToPtr(new Header { Data = data, Length = 24000 }, hdr, false);
                Check(waveInPrepareHeader(handle, hdr, headerSize));
                Check(waveInAddBuffer(handle, hdr, headerSize));
            }
            start = session.Now;
            Check(waveInStart(handle));
        }
        catch { Dispose(); throw; }
    }
    void OpenPart()
    {
        string name = "audio_" + Guid.NewGuid().ToString("N")[..12] + ".wav";
        writer = new BinaryWriter(new FileStream(Path.Combine(session.Folder, name), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read));
        bytes = 0;
        WriteHeader();
        session.Audio.Add(new() { File = name, Start = start + totalSamples / 48000.0 });
        session.Save();
    }
    void WriteHeader()
    {
        var s = writer.BaseStream;
        s.Position = 0;
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + bytes);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((ushort)1); writer.Write((ushort)1); writer.Write(48000); writer.Write(96000);
        writer.Write((ushort)2); writer.Write((ushort)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(bytes);
        s.Position = 44L + bytes;
        writer.Flush();
    }
    void Drain(bool requeue)
    {
        for (int count = 0; count < buffers.Count; count++)
        {
            var b = buffers[nextBuffer];
            var h = Marshal.PtrToStructure<Header>(b.Header);
            if ((h.Flags & 1) == 0) break;
            if (h.Recorded > 0)
            {
                lastBuffer = Environment.TickCount64;
                byte[] data = new byte[h.Recorded]; Marshal.Copy(h.Data, data, 0, data.Length);
                int peak = 0;
                for (int j = 0; j + 1 < data.Length; j += 2) peak = Math.Max(peak, Math.Abs((int)BitConverter.ToInt16(data, j)));
                Level = peak / 32768f;
                if (writer == null) OpenPart();
                writer.Write(data); bytes += data.Length; totalSamples += data.Length / 2;
                WriteHeader(); // Each completed buffer leaves a readable WAV, even after an interrupted session.
                if (bytes >= 30 * 96000) { writer.Dispose(); writer = null; }
            }
            if (requeue) Check(waveInAddBuffer(handle, b.Header, headerSize));
            nextBuffer = (nextBuffer + 1) % buffers.Count;
        }
    }
    public void Poll()
    {
        Drain(true);
        if (Environment.TickCount64 - lastBuffer > 4000) throw new Exception("Microphone stopped delivering audio. Recording paused; check the headset connection.");
    }
    public void Dispose()
    {
        try
        {
            if (handle != IntPtr.Zero)
            {
                waveInReset(handle);
                try { Drain(false); } finally
                {
                    foreach (var b in buffers) waveInUnprepareHeader(handle, b.Header, headerSize);
                    waveInClose(handle); handle = IntPtr.Zero;
                }
            }
        }
        finally
        {
            writer?.Dispose(); writer = null;
            foreach (var b in buffers) { Marshal.FreeHGlobal(b.Header); Marshal.FreeHGlobal(b.Data); }
            buffers.Clear();
            lease?.Dispose(); lease = null;
        }
    }
}
