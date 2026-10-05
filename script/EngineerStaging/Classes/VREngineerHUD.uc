// One renderer supplies the desktop overlay and the VR tool-local display.
// Original TF2 menu textures/fonts still require the visual parity gate.
class VREngineerHUD extends Actor;

var VREngineerState Engineer;
var VREngineerPanel Panels[2];
var VRHandsBridge Bridge;

simulated function DrawTextAt(Canvas C, string Text, float X, float Y, optional float Scale=1)
{
    C.SetPos(X, Y);
    C.DrawText(Text, false, Scale, Scale);
}

simulated function RenderMenu(Canvas C, optional bool Destruction)
{
    local int I, Cost;
    local float X;
    local string Title, Label, StateText;
    local bool Supported, Affordable;
    if (Engineer == None || !Engineer.IsOwnerAlive()) return;
    Title = Destruction ? "DESTROY" : "BUILD";
    C.SetDrawColor(245,232,208,255);
    DrawTextAt(C, Title, 16, 12, 1.3);
    DrawTextAt(C, "METAL " $ Engineer.Metal, 500, 14);
    for (I = 0; I < 4; ++I)
    {
        X = 16 + I * 156;
        Supported = I == 0;
        Cost = class'VREngineerRules'.static.BuildCost(EngineerBuildingSlot(I));
        Affordable = Supported && Engineer.Metal >= Cost && Engineer.Sentry == None;
        C.SetDrawColor(44,41,38,230); C.SetPos(X, 50); C.DrawRect(146, 136);
        if (I == 0) Label = "SENTRY GUN";
        else if (I == 1) Label = "DISPENSER";
        else Label = I == 2 ? "ENTRANCE" : "EXIT";
        C.SetDrawColor(210,200,180,255);
        DrawTextAt(C, string(I + 1) @ Label, X + 8, 62, 0.75);
        DrawTextAt(C, string(Cost) @ "METAL", X + 8, 108, 0.85);
        if (!Supported) StateText = "UNAVAILABLE";
        else if (Destruction) StateText = Engineer.Sentry == None ? "NOT BUILT" : "DESTROY";
        else if (Engineer.Sentry != None) StateText = "ALREADY BUILT";
        else StateText = Affordable ? "SELECT" : "NOT ENOUGH METAL";
        C.SetDrawColor(Affordable ? 235 : 135, Affordable ? 196 : 135, Affordable ? 115 : 135, 255);
        DrawTextAt(C, StateText, X + 8, 153, 0.65);
    }
}

simulated event PostRenderFor(PlayerController PC, Canvas C, vector CameraPosition, vector CameraDir)
{
    local float SavedX, SavedY;
    if (Engineer == None || Engineer.PC != PC || !Engineer.IsOwnerAlive() || PC.IsPaused()) return;
    if (Bridge != None && Bridge.NativeConnection == 1 && !Bridge.bReplay) return;
    SavedX = C.OrgX; SavedY = C.OrgY;
    if (Engineer.Builder.Weapon == Engineer.ConstructionPDA || Engineer.Builder.Weapon == Engineer.DestructionPDA)
    {
        C.SetOrigin((C.SizeX - 656) * 0.5, C.SizeY * 0.2);
        RenderMenu(C, Engineer.Builder.Weapon == Engineer.DestructionPDA);
    }
    else if (Engineer.Builder.Weapon == Engineer.Toolbox)
    {
        C.SetDrawColor(245,232,208,255);
        DrawTextAt(C, "PRIMARY: PLACE   SECONDARY: ROTATE   SWITCH WEAPON: CANCEL", 20, C.SizeY - 120, 0.75);
        if (Engineer.Toolbox.InvalidReason != "") DrawTextAt(C, Engineer.Toolbox.InvalidReason, 20, C.SizeY - 96);
    }
    C.SetOrigin(SavedX, SavedY);
    C.SetDrawColor(245,232,208,255);
    DrawTextAt(C, "METAL " $ Engineer.Metal, 20, C.SizeY - 66);
    if (Engineer.Sentry != None)
        DrawTextAt(C, "SENTRY " $ Engineer.Sentry.BuildingLevel @ "HP" @ Engineer.Sentry.Health
            @ "SHELLS" @ Engineer.Sentry.Shells @ "ROCKETS" @ Engineer.Sentry.Rockets, 20, C.SizeY - 42, 0.75);
}

simulated event Tick(float DeltaTime)
{
    local VRHandsBridge Candidate;
    local VRHandsBridge Presenter;
    local VRWeaponRuntime R;
    local VREngineerWeapon Tool;
    local int Hand;
    if (Engineer == None || !Engineer.IsOwnerAlive()) { Destroy(); return; }
    if (Bridge == None)
        foreach WorldInfo.AllActors(class'VRHandsBridge', Candidate)
            if (Candidate.Human == Engineer.Builder && Candidate.RootBridge == None) { Bridge = Candidate; break; }
    if (Bridge != None) class'VREngineerVR'.static.RegisterTools(Bridge);
    for (Hand = 0; Hand < 2; ++Hand)
    {
        Presenter = None; Tool = None;
        if (Bridge != None && Bridge.NativeConnection == 1 && Bridge.NativeMenuActive == 0
            && (Bridge.NativeValidMask & (1 << Hand)) != 0)
        {
            if (Bridge.NativeIndependentHands != 0 && Bridge.HeldInventory != None)
            {
                R = Bridge.HeldInventory.GetPrimary(Hand);
                if (R != None && R.IsCurrent() && R.PrimaryHand == Hand && R.Presenter != None)
                { Presenter = R.Presenter; Tool = VREngineerWeapon(R.Item); }
            }
            else if (Hand == Bridge.WeaponHand)
            { Presenter = Bridge; Tool = VREngineerWeapon(Engineer.Builder.Weapon); }
        }
        if (Presenter != None && Tool != None && Tool.IsSelectedTool()
            && (Tool == Engineer.ConstructionPDA || Tool == Engineer.DestructionPDA))
        {
            if (Panels[Hand] == None)
            {
                Panels[Hand] = Spawn(class'VREngineerPanel', self);
                if (Panels[Hand] != None) Panels[Hand].Initialize(self);
            }
            if (Panels[Hand] != None)
            {
                Panels[Hand].bDestruction = Tool == Engineer.DestructionPDA;
                Panels[Hand].Place(Presenter.Hands[Hand].Position + vector(Presenter.BodyRotation) * 30
                    + vect(0,0,24), Presenter.BodyRotation);
            }
        }
        else if (Panels[Hand] != None) Panels[Hand].SetHidden(true);
    }
}

simulated event Destroyed()
{
    local int Hand;
    for (Hand = 0; Hand < 2; ++Hand)
        if (Panels[Hand] != None) Panels[Hand].Destroy();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bPostRenderIfNotVisible=true
}
