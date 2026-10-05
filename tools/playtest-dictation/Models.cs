using System.Text.Json;

namespace Playtest;

internal static class Files
{
    public static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, WriteIndented = true };
    // Share delete so the processor can atomically replace a status file while it is being polled.
    public static T Read<T>(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return JsonSerializer.Deserialize<T>(stream, Json);
    }
    public static void Save<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        string temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(value, Json));
        File.Move(temp, path, true);
    }
}

internal sealed class SessionLease : IDisposable
{
    readonly FileStream stream;
    public SessionLease(string folder)
    {
        stream = new FileStream(Path.Combine(folder, "processing.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.ReadWrite);
        try { stream.Lock(0, 1); }
        catch { stream.Dispose(); throw new IOException("This session is being processed. Wait for the report before changing it."); }
    }
    public void Dispose() { stream.Unlock(0, 1); stream.Dispose(); }
}

internal sealed class Config
{
    public string NotesDir { get; set; }
    public string Python { get; set; }
    public string Checklist { get; set; }
    public string Microphone { get; set; } = "";
    public bool ShowHud { get; set; } = true;
    public double HudWidth { get; set; } = 0.48;
    public double HudY { get; set; } = -0.38;
    public double HudZ { get; set; } = -1.1;
    // Keep the complete JSON when updating preferences: processing settings belong to Python.
    public static void Preference(string path, string key, object value)
    {
        var doc = Files.Read<Dictionary<string, JsonElement>>(path);
        doc[key] = JsonSerializer.SerializeToElement(value);
        Files.Save(path, doc);
    }
}

internal sealed class Phase
{
    public string Weapon { get; set; }
    public string Scenario { get; set; }
    public string Instruction { get; set; }
    public string Watch { get; set; } = "";
}
internal sealed class NoteEvent
{
    public string Kind { get; set; }
    public double At { get; set; }
    public int Phase { get; set; }
    public double? Lookback { get; set; }
    public string Detail { get; set; }
}
internal sealed class AudioPart
{
    public string File { get; set; }
    public double Start { get; set; }
}
internal sealed class Session
{
    public int Schema { get; set; } = 1;
    public string Id { get; set; }
    public DateTimeOffset StartedUtc { get; set; }
    public string SelectedRelease { get; set; }
    public string Status { get; set; } = "paused";
    public int PhaseIndex { get; set; }
    public List<Phase> Phases { get; set; } = [];
    public List<NoteEvent> Events { get; set; } = [];
    public List<AudioPart> Audio { get; set; } = [];
    [System.Text.Json.Serialization.JsonIgnore] public string Folder { get; set; }
    [System.Text.Json.Serialization.JsonIgnore] public string PathName => Path.Combine(Folder, "session.json");
    [System.Text.Json.Serialization.JsonIgnore] public double Now => Math.Max(0, (DateTimeOffset.UtcNow - StartedUtc).TotalSeconds);
    public void Save() => Files.Save(PathName, this);
    public void Mark(string kind, string detail = null, double? lookback = null)
    {
        Events.Add(new() { Kind = kind, At = Now, Phase = PhaseIndex, Detail = detail, Lookback = lookback });
        Save();
    }
    public static Session Create(Config config, string repo, string releaseOverride)
    {
        var phases = Files.Read<List<Phase>>(config.Checklist);
        if (phases == null || phases.Count == 0 || phases.Any(p => string.IsNullOrWhiteSpace(p.Weapon) || string.IsNullOrWhiteSpace(p.Scenario)))
            throw new Exception("Checklist needs at least one phase with weapon and scenario.");
        string release = releaseOverride;
        string pointer = Path.Combine(repo, "build", "multiplayer", "current-release.json");
        if (string.IsNullOrWhiteSpace(release) && File.Exists(pointer))
            release = Files.Read<Dictionary<string, JsonElement>>(pointer).GetValueOrDefault("release").ToString();
        string id = DateTime.Now.ToString("yyyy-MM-dd_HHmmss") + "_" + Guid.NewGuid().ToString("N")[..6];
        var session = new Session { Id = id, StartedUtc = DateTimeOffset.UtcNow, SelectedRelease = release ?? "unknown", Phases = phases,
            Folder = Path.Combine(config.NotesDir, "raw", id) };
        session.Mark("phase");
        return session;
    }
    public static Session Resume(string path)
    {
        var s = Files.Read<Session>(path);
        if (s.Schema != 1 || s.Phases.Count == 0 || s.PhaseIndex < 0 || s.PhaseIndex >= s.Phases.Count) throw new Exception("Invalid saved session.");
        s.Folder = Path.GetDirectoryName(path);
        if (s.Status != "finished") { s.Status = "paused"; s.Mark("resumed", "Recording paused until explicitly started."); }
        return s;
    }
}
