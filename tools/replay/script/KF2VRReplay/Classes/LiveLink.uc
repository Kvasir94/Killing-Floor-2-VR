// Live control link for ScriptRunner (tools/replay/live.py). The game dials
// out to the live.py session broker on 127.0.0.1 (an outbound connection, so
// no firewall prompt), says which client it is, then exchanges one text line
// per message: compiled ops and controls in, the runner's notes, captures and
// replies out. The runner owns every decision; this class only moves lines.
class LiveLink extends TcpLink;

var ScriptRunner Runner;
var string Pending;
var int Client;
var bool bOpened;
var float OpenedAt;

function Connect(ScriptRunner From, int PortNumber, int ClientId)
{
    local IpAddr Address;
    Runner = From; Client = ClientId;
    LinkMode = MODE_Text; ReceiveMode = RMODE_Event;
    OpenedAt = WorldInfo.RealTimeSeconds;
    if (!StringToIpAddr("127.0.0.1", Address)) { Runner.Note(0, "live link address refused"); return; }
    Address.Port = PortNumber;
    if (BindPort() == 0) { Runner.Note(0, "live link bind failed error=" $ GetLastError()); return; }
    if (!Open(Address)) Runner.Note(0, "live link open failed error=" $ GetLastError());
}

event Opened()
{
    bOpened = true;
    SendText("HELLO game client=" $ Client $ Chr(10));
    Runner.LinkOpened();
}

event Closed()
{
    bOpened = false;
}

event ReceivedText(string Text)
{
    local int At;
    local string Line;
    Pending $= Text;
    At = InStr(Pending, Chr(10));
    while (At >= 0)
    {
        Line = Left(Pending, At);
        Pending = Mid(Pending, At + 1);
        if (Right(Line, 1) == Chr(13)) Line = Left(Line, Len(Line) - 1);
        if (Line != "") Runner.LiveLine(Line);
        At = InStr(Pending, Chr(10));
    }
}

function Say(string Text)
{
    if (bOpened && IsConnected()) SendText(Text $ Chr(10));
}

defaultproperties
{
}
