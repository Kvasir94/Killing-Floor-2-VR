using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Valve.VR;

namespace Playtest;

internal sealed class Overlay : IDisposable
{
    CVROverlay vr;
    ulong dashboard, thumbnail, hud;
    bool initialized;
    public bool Connected => vr != null;
    public string Status { get; private set; } = "SteamVR not connected";
    public void Connect(Config config)
    {
        if (Connected) return;
        try
        {
            if (System.Diagnostics.Process.GetProcessesByName("vrserver").Length == 0)
            { Status = "Start SteamVR to connect the overlay"; return; }
            var error = EVRInitError.None;
            OpenVR.Init(ref error, EVRApplicationType.VRApplication_Overlay);
            if (error != EVRInitError.None) { Status = "Start SteamVR to connect the overlay (" + error + ")"; return; }
            initialized = true;
            vr = OpenVR.Overlay ?? throw new Exception("SteamVR overlay interface unavailable.");
            Check(vr.CreateDashboardOverlay("kf2vr.playtest.dashboard", "KF2-VR Playtest", ref dashboard, ref thumbnail));
            Check(vr.SetOverlayWidthInMeters(dashboard, 1.25f));
            Check(vr.SetOverlayInputMethod(dashboard, VROverlayInputMethod.Mouse));
            var scale = new HmdVector2_t { v0 = Panel.Width, v1 = Panel.Height };
            Check(vr.SetOverlayMouseScale(dashboard, ref scale));
            Check(vr.CreateOverlay("kf2vr.playtest.status", "KF2-VR Playtest status", ref hud));
            Check(vr.SetOverlayWidthInMeters(hud, (float)config.HudWidth));
            Check(vr.SetOverlayInputMethod(hud, VROverlayInputMethod.None));
            var transform = new HmdMatrix34_t { m0 = 1, m5 = 1, m10 = 1, m7 = (float)config.HudY, m11 = (float)config.HudZ };
            Check(vr.SetOverlayTransformTrackedDeviceRelative(hud, OpenVR.k_unTrackedDeviceIndex_Hmd, ref transform));
            using var icon = new Bitmap(128, 128);
            using (var g = Graphics.FromImage(icon))
            using (var font = new Font("Segoe UI", 26, FontStyle.Bold))
            { g.Clear(Color.FromArgb(20, 31, 45)); g.DrawString("KF2\nTEST", font, Brushes.White, 7, 7); }
            Upload(thumbnail, icon);
            Status = "SteamVR connected — open dashboard > KF2-VR Playtest";
        }
        catch (Exception ex) { Dispose(); Status = "Overlay: " + ex.Message; }
    }
    static void Check(EVROverlayError e) { if (e != EVROverlayError.None) throw new Exception(e.ToString()); }
    public void Poll(Action<int, int> click)
    {
        if (!Connected) return;
        var e = new VREvent_t();
        uint size = (uint)Marshal.SizeOf<VREvent_t>();
        while (vr.PollNextOverlayEvent(dashboard, ref e, size))
        {
            if (e.eventType == (uint)EVREventType.VREvent_Quit) { Dispose(); Status = "SteamVR closed — desktop recording remains available"; return; }
            if (e.eventType == (uint)EVREventType.VREvent_MouseButtonUp && e.data.mouse.button == 1)
                click((int)e.data.mouse.x, Panel.Height - (int)e.data.mouse.y);
        }
        while (OpenVR.System != null && OpenVR.System.PollNextEvent(ref e, size))
            if (e.eventType == (uint)EVREventType.VREvent_Quit) { Dispose(); Status = "SteamVR closed"; return; }
    }
    public void Render(Bitmap panel, Bitmap status, bool visible)
    {
        if (!Connected) return;
        if (vr.IsOverlayVisible(dashboard)) Upload(dashboard, panel);
        if (visible && !vr.IsDashboardVisible()) { Upload(hud, status); Check(vr.ShowOverlay(hud)); }
        else vr.HideOverlay(hud);
    }
    void Upload(ulong overlay, Bitmap bitmap)
    {
        var rect = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        var data = bitmap.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            byte[] rgba = new byte[bitmap.Width * bitmap.Height * 4];
            for (int y = 0; y < bitmap.Height; y++)
                Marshal.Copy(data.Scan0 + y * data.Stride, rgba, y * bitmap.Width * 4, bitmap.Width * 4);
            for (int i = 0; i < rgba.Length; i += 4) (rgba[i], rgba[i + 2]) = (rgba[i + 2], rgba[i]);
            var pin = GCHandle.Alloc(rgba, GCHandleType.Pinned);
            try { Check(vr.SetOverlayRaw(overlay, pin.AddrOfPinnedObject(), (uint)bitmap.Width, (uint)bitmap.Height, 4)); }
            finally { pin.Free(); }
        }
        finally { bitmap.UnlockBits(data); }
    }
    public void Dispose()
    {
        if (vr != null) { if (hud != 0) vr.DestroyOverlay(hud); if (dashboard != 0) vr.DestroyOverlay(dashboard); if (thumbnail != 0) vr.DestroyOverlay(thumbnail); }
        vr = null; hud = dashboard = thumbnail = 0;
        if (initialized) { OpenVR.Shutdown(); initialized = false; }
    }
}

internal static class Panel
{
    public const int Width = 1000, Height = 680;
    public static readonly (string Id, Rectangle Rect)[] Buttons = [
        ("back", new(35, 395, 285, 66)), ("next", new(355, 395, 285, 66)), ("bug", new(675, 395, 290, 66)),
        ("record", new(35, 478, 285, 66)), ("finish", new(355, 478, 285, 66)), ("hud", new(675, 478, 290, 66)),
        ("process", new(35, 561, 285, 66)), ("copy", new(355, 561, 285, 66)), ("new", new(675, 561, 290, 66)) ];
    static void Text(Graphics g, string text, int size, Color color, Rectangle box, bool bold = false)
    {
        using var font = new Font("Segoe UI", size, bold ? FontStyle.Bold : FontStyle.Regular, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(color);
        using var format = new StringFormat { Trimming = StringTrimming.EllipsisCharacter };
        g.DrawString(text ?? "", font, brush, box, format);
    }
    public static Bitmap Draw(Session session, bool recording, float level, string notice, bool busy, bool hudVisible, bool compact = false)
    {
        var bmp = new Bitmap(compact ? 700 : Width, compact ? 230 : Height);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.FromArgb(18, 25, 36));
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        var phase = session.Phases[session.PhaseIndex];
        string title = phase.Weapon + "  ·  " + (session.PhaseIndex + 1) + " / " + session.Phases.Count;
        string state = recording ? "RECORDING" : session.Status == "finished" ? "SAVED" : "PAUSED";
        string next = session.PhaseIndex + 1 < session.Phases.Count
            ? "Next: " + session.Phases[session.PhaseIndex + 1].Weapon + " — " + session.Phases[session.PhaseIndex + 1].Scenario
            : "Last phase — Finish when ready";
        Color accent = recording ? Color.FromArgb(64, 220, 163) : Color.FromArgb(255, 201, 96);
        Text(g, title, compact ? 30 : 35, Color.White, new(25, 16, compact ? 650 : 950, 48), true);
        Text(g, phase.Scenario, compact ? 27 : 40, Color.White, new(25, compact ? 60 : 72, compact ? 650 : 950, compact ? 40 : 66), true);
        if (compact)
        {
            Text(g, state + "  |  " + notice, 22, accent, new(25, 109, 650, 58));
            Text(g, next, 20, Color.LightSteelBlue, new(25, 175, 650, 35));
            g.FillRectangle(Brushes.MediumAquamarine, 25, 217, (int)(650 * Math.Min(1, level * 3)), 6);
            return bmp;
        }
        Text(g, phase.Instruction, 28, Color.Gainsboro, new(35, 147, 930, 70));
        Text(g, string.IsNullOrWhiteSpace(phase.Watch) ? "" : "Watch: " + phase.Watch, 23, Color.LightSteelBlue, new(35, 220, 930, 60));
        Text(g, state + "  ·  " + TimeSpan.FromSeconds(session.Now).ToString(@"hh\:mm\:ss") + "  ·  " + notice,
            22, accent, new(35, 285, 930, 68));
        g.FillRectangle(Brushes.DimGray, 35, 365, 930, 8);
        g.FillRectangle(Brushes.MediumAquamarine, 35, 365, (int)(930 * Math.Min(1, level * 3)), 8);
        foreach (var (id, rect) in Buttons)
        {
            string label = id switch { "back" => "Previous", "next" => "Next", "bug" => "Mark bug −15s", "record" => recording ? "Pause recording" : "Start recording", "finish" => "Finish / save", "hud" => hudVisible ? "Hide status panel" : "Show status panel", "process" => busy ? "Processing…" : "Process now", "copy" => "Copy report", _ => "New session" };
            using var brush = new SolidBrush(id == "bug" ? Color.FromArgb(119, 61, 43) : Color.FromArgb(39, 59, 80));
            g.FillRectangle(brush, rect);
            Text(g, label, 26, Color.White, new(rect.X + 14, rect.Y + 17, rect.Width - 20, 45));
        }
        Text(g, next + "  ·  Advancing never means PASS.", 18, Color.LightSlateGray, new(35, 643, 930, 30));
        return bmp;
    }
}
