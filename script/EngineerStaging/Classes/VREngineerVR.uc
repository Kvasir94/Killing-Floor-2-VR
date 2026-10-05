// Profiles are registered only when the optional Engineer kit is present.
// Every tool remains a normal inventory weapon; tracked controls use the same
// authoritative actions as desktop input.
class VREngineerVR extends Object;

static function RegisterTools(VRHandsBridge Bridge)
{
    local name ToolNames[5];
    local int I, J;
    local bool Found, Added;
    local KFWeapon Current;
    if (Bridge == None) return;
    ToolNames[0] = 'VREngineerPDA'; ToolNames[1] = 'VREngineerToolbox';
    ToolNames[2] = 'VREngineerWrench'; ToolNames[3] = 'VREngineerDestroyPDA';
    ToolNames[4] = 'VREngineerWrangler';
    for (I = 0; I < 5; ++I)
    {
        Found = false;
        for (J = 0; J < Bridge.WeaponProfiles.Length; ++J)
            if (Bridge.WeaponProfiles[J].WeaponClassName == ToolNames[I]) { Found = true; break; }
        if (!Found)
        {
            // Use the canonical array's element type directly; UE3 analyzes
            // this helper before the bridge's nested struct declaration.
            J = Bridge.WeaponProfiles.Length;
            Bridge.WeaponProfiles.Add(1);
            Bridge.WeaponProfiles[J].WeaponClassName = ToolNames[I];
            Bridge.WeaponProfiles[J].RootBone = 'RW_Weapon';
            Bridge.WeaponProfiles[J].IdleAnimation = 'Idle';
            Bridge.WeaponProfiles[J].MuzzleSocket = 'MuzzleFlash';
            Added = true;
        }
    }
    if (Added && VREngineerWeapon(Bridge.ActiveWeapon) != None && Bridge.ActiveProfile < 0)
    {
        Current = Bridge.ActiveWeapon;
        Bridge.ConfigureWeapon(None);
        Bridge.ConfigureWeapon(Current);
    }
}

static function RegisterOwner(Pawn Builder)
{
    local VRHandsBridge B;
    if (Builder == None) return;
    foreach Builder.WorldInfo.AllActors(class'VRHandsBridge', B)
        if (B.Human == Builder && B.RootBridge == None) RegisterTools(B);
}

static function bool SwitchTool(VREngineerWeapon From, VREngineerWeapon To,
    optional bool bUseAlreadyHeld)
{
    local VRHandsBridge B;
    local VRWeaponRuntime R, Target;
    local bool PreviousReleaseGate;
    if (From == None || To == None || !From.IsSelectedTool(true)
        || To.Instigator != From.Instigator || To.InvManager != From.InvManager) return false;
    if (From.HasManagedHands())
    {
        B = From.TrackedBridge.RootBridge;
        R = From.TrackedBridge.PresentedItem;
        RegisterTools(B);
        Target = B.HeldInventory.FindItem(To);
        // A wrench already in the other hand stays there. Finish the toolbox
        // action by stowing that hand, without cloning or moving the wrench.
        if (bUseAlreadyHeld && Target != None && Target.IsCurrent() && Target.PrimaryHand == 1 - R.PrimaryHand
            && B.HeldInventory.GetPrimary(Target.PrimaryHand) == Target)
            return B.HandInventory.ReleaseHand(R.PrimaryHand);
        PreviousReleaseGate = To.bTrackedInputNeedsRelease;
        To.bTrackedInputNeedsRelease = true;
        if (B.HandInventory.Draw(R.PrimaryHand, To)) return true;
        To.bTrackedInputNeedsRelease = PreviousReleaseGate;
        To.Class.static.TriggerAsyncContentLoad(To.Class);
        return false;
    }
    From.Instigator.InvManager.SetCurrentWeapon(To);
    return true;
}
