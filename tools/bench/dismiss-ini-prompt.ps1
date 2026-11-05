# Answers KF2's startup "Your ini ... is outdated" box with "No" (keep the launcher's ini as written),
# so unattended #148 benchmark launches don't stall. Runs until -Seconds elapse.
param([int]$Seconds = 600)
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public class KfPrompt {
  delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static string AnswerNo(uint pid) {
    string done = null;
    EnumWindows((h,l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var s = new StringBuilder(256); GetWindowText(h, s, 256); if (s.ToString() != "Message") return true;
      IntPtr no = IntPtr.Zero; string text = "";
      EnumChildWindows(h, (c,x) => { var t = new StringBuilder(4096); GetWindowText(c, t, 4096); var v = t.ToString();
        if (v == "No") no = c; else if (v.Contains("is outdated")) text = v; return true; }, IntPtr.Zero);
      if (no != IntPtr.Zero && text != "") { SendMessage(no, 0x00F5, IntPtr.Zero, IntPtr.Zero); done = text; }
      return true; }, IntPtr.Zero);
    return done; }
}
'@
$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) {
  foreach ($p in Get-Process KFGame -ErrorAction SilentlyContinue) {
    $r = [KfPrompt]::AnswerNo([uint32]$p.Id)
    if ($r) { "answered No: $r" }
  }
  Start-Sleep -Milliseconds 500
}
