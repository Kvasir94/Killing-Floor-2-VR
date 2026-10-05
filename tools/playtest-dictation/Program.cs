using System.Diagnostics;
using System.Text.Json;

namespace Playtest;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        using var mutex = new Mutex(true, "Local\\KF2VR_PlaytestCompanion", out bool first);
        if (!first) { MessageBox.Show("The playtest companion is already open."); return; }
        try
        {
            if (args.Length < 2) throw new Exception("Start with Playtest-Dictation.ps1.");
            Application.Run(new Companion(args[0], args[1], args.Length > 2 ? args[2] : null));
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "KF2-VR Playtest", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}

internal sealed class Companion : Form
{
    readonly string repo, configPath, releaseOverride;
    readonly Config config;
    readonly PictureBox view = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom };
    readonly ComboBox mic = new() { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
    readonly Label connection = new() { AutoSize = true, Padding = new(8) };
    readonly System.Windows.Forms.Timer timer = new() { Interval = 50 };
    readonly Overlay overlay = new();
    Session session;
    Recorder recorder;
    Process processor;
    string notice = "Choose microphone, then Start recording";
    long renderAt, connectAt;
    bool closing;
    bool Busy => processor != null;
    string ActivePath => Path.Combine(config.NotesDir, "active.json");
    public Companion(string repo, string configPath, string releaseOverride)
    {
        this.repo = repo; this.configPath = configPath; this.releaseOverride = releaseOverride;
        config = Files.Read<Config>(configPath);
        Directory.CreateDirectory(config.NotesDir);
        if (File.Exists(ActivePath))
        {
            string path = Files.Read<Dictionary<string, string>>(ActivePath)["session"];
            if (File.Exists(path)) session = Session.Resume(path);
        }
        session ??= Session.Create(config, repo, releaseOverride);
        SaveActive();
        Text = "KF2-VR Playtest Companion"; ClientSize = new(1000, 765); MinimumSize = new(800, 660);
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 80, Padding = new(8), WrapContents = true };
        top.Controls.Add(new Label { Text = "Microphone:", AutoSize = true, Padding = new(0, 7, 0, 0) }); top.Controls.Add(mic);
        var refresh = new Button { Text = "Refresh mics", AutoSize = true };
        refresh.Click += (_, _) => Guard(RefreshMics); top.Controls.Add(refresh);
        var folder = new Button { Text = "Open notes", AutoSize = true };
        folder.Click += (_, _) => Process.Start(new ProcessStartInfo(config.NotesDir) { UseShellExecute = true }); top.Controls.Add(folder);
        top.Controls.Add(connection);
        Controls.Add(view); Controls.Add(top);
        RefreshMics();
        mic.SelectedIndexChanged += (_, _) => Guard(() => {
            if (recorder != null) Pause();
            config.Microphone = mic.SelectedItem?.ToString() ?? "";
            Config.Preference(configPath, "microphone", config.Microphone);
            notice = "Microphone selected; start recording to check the meter";
        });
        view.MouseUp += (_, e) => {
            if (e.Button != MouseButtons.Left) return;
            double scale = Math.Min(view.Width / (double)Panel.Width, view.Height / (double)Panel.Height);
            int x = (int)((e.X - (view.Width - Panel.Width * scale) / 2) / scale);
            int y = (int)((e.Y - (view.Height - Panel.Height * scale) / 2) / scale);
            ClickPanel(x, y);
        };
        timer.Tick += (_, _) => Tick(); timer.Start();
        FormClosing += (_, e) => {
            if (Busy) { e.Cancel = true; notice = "Processing is still running. Wait for the report before closing."; return; }
            closing = true; timer.Stop(); Guard(Pause); overlay.Dispose(); view.Image?.Dispose();
        };
    }
    void SaveActive() => Files.Save(ActivePath, new Dictionary<string, string> { ["session"] = session.PathName });
    void RefreshMics()
    {
        if (recorder != null) throw new Exception("Pause recording before refreshing microphones.");
        mic.Items.Clear(); mic.Items.AddRange(Recorder.Devices().Cast<object>().ToArray());
        if (mic.Items.Contains(config.Microphone)) mic.SelectedItem = config.Microphone;
    }
    void Guard(Action action)
    {
        try { action(); }
        catch (Exception ex) { notice = ex.Message; }
    }
    void Pause()
    {
        if (recorder == null) return;
        var old = recorder; recorder = null;
        try { old.Dispose(); } finally { session.Status = "paused"; session.Mark("pause"); }
        notice = "Recording paused — audio saved";
    }
    void ClickPanel(int x, int y)
    {
        foreach (var (id, rect) in Panel.Buttons)
            if (rect.Contains(x, y)) { Guard(() => Act(id)); break; }
        renderAt = 0;
    }
    void Act(string id)
    {
        if (Busy && id != "hud") { notice = "Processing this session; wait for completion"; return; }
        using var lease = recorder == null && (id is "back" or "next" or "bug" or "finish" or "new") ? new SessionLease(session.Folder) : null;
        switch (id)
        {
            case "back": case "next":
                if (session.Status == "finished") { notice = "Session saved. Choose New session for another test."; return; }
                int target = session.PhaseIndex + (id == "next" ? 1 : -1);
                if (target < 0 || target >= session.Phases.Count) { notice = target < 0 ? "First phase" : "Last phase — Finish when ready"; return; }
                recorder?.Poll(); session.PhaseIndex = target; session.Mark("phase"); notice = "Phase changed; no result assumed"; break;
            case "record":
                if (recorder != null) Pause();
                else
                {
                    if (session.Status == "finished") { notice = "Choose New session to record again"; return; }
                    recorder = new Recorder(session, config.Microphone); session.Status = "recording"; session.Mark("record", config.Microphone); notice = "Recording — check the microphone meter";
                }
                break;
            case "bug":
                if (session.Status == "finished") return;
                session.Mark("bug", "User bookmark; details come from speech, not this marker.", Math.Max(0, session.Now - 15)); notice = "Bug bookmarked, including previous 15 seconds"; break;
            case "finish": Pause(); session.Status = "finished"; session.Mark("finish"); notice = "Saved. Process now, or close and process later."; break;
            case "hud": config.ShowHud = !config.ShowHud; Config.Preference(configPath, "show_hud", config.ShowHud); break;
            case "new":
                if (recorder != null || session.Status != "finished") { notice = "Finish the current session before starting another"; return; }
                session = Session.Create(config, repo, releaseOverride); SaveActive(); notice = "New session — ready to record"; break;
            case "process":
                if (recorder != null) { notice = "Pause or finish recording before processing"; return; }
                if (session.Audio.Count == 0) { notice = "No audio recorded yet"; return; }
                if (Process.GetProcessesByName("KFGame").Length > 0) { notice = "Exit KF2 before processing; your audio is already saved"; return; }
                StartProcessing(); break;
            case "copy":
                string latest = Path.Combine(session.Folder, "latest-report.json");
                if (!File.Exists(latest)) { notice = "Process this session to create a report first"; return; }
                Clipboard.SetText(File.ReadAllText(Files.Read<Dictionary<string, string>>(latest)["path"])); notice = "Report copied — paste when ready"; break;
        }
    }
    void StartProcessing()
    {
        string status = Path.Combine(session.Folder, "processing.json");
        if (File.Exists(status)) File.Delete(status);
        var info = new ProcessStartInfo(config.Python) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = repo };
        foreach (string arg in new[] { Path.Combine(repo, "tools", "playtest-dictation", "process.py"), "--config", configPath, "--session", session.PathName, "--copy" }) info.ArgumentList.Add(arg);
        processor = Process.Start(info) ?? throw new Exception("Could not start local processing.");
        notice = "Starting local transcription…";
    }
    void Tick()
    {
        if (closing) return;
        if (recorder != null)
        {
            try { recorder.Poll(); }
            catch (Exception ex) { Guard(Pause); notice = ex.Message; session.Mark("audio_error", ex.Message); }
        }
        long now = Environment.TickCount64;
        if (now >= connectAt && !overlay.Connected) { overlay.Connect(config); connectAt = now + 10000; }
        try { overlay.Poll(ClickPanel); }
        catch (Exception ex) { overlay.Dispose(); notice = "Overlay disconnected: " + ex.Message; }
        if (Busy)
        {
            string path = Path.Combine(session.Folder, "processing.json");
            if (File.Exists(path)) Guard(() => notice = Files.Read<Dictionary<string, JsonElement>>(path)["message"].GetString());
            if (processor.HasExited)
            {
                if (processor.ExitCode != 0 && !File.Exists(path)) notice = "Processing failed; audio and transcript preserved. See README for retry.";
                processor.Dispose(); processor = null;
            }
        }
        if (now < renderAt) return;
        renderAt = now + 250;
        connection.Text = overlay.Status;
        using var compact = Panel.Draw(session, recorder != null, recorder?.Level ?? 0, notice, Busy, config.ShowHud, true);
        var image = Panel.Draw(session, recorder != null, recorder?.Level ?? 0, notice, Busy, config.ShowHud);
        var oldImage = view.Image; view.Image = image; oldImage?.Dispose();
        try { overlay.Render(image, compact, config.ShowHud); }
        catch (Exception ex) { overlay.Dispose(); notice = "Overlay: " + ex.Message; }
    }
}
