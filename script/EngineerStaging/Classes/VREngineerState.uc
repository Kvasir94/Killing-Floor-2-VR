// A single shared metal pool and building registry per pawn lifetime. Equipment
// changes never grant metal, clone a sentry, or spend a placement reservation.
class VREngineerState extends Actor;

var KFPawn_Human Builder;
var KFPlayerController PC;
var VREngineerPDA ConstructionPDA;
var VREngineerDestroyPDA DestructionPDA;
var VREngineerToolbox Toolbox;
var VREngineerWrench Wrench;
var VREngineerSentry Sentry;
var VREngineerRules.EngineerBuildingSlot SelectedBlueprint;
var int Metal;
var bool bBlueprintSelected, bShuttingDown, bKitCommitted;
var VREngineerHUD EngineerHUD;
var VREngineerInput EngineerInput;

function bool IsOwnerAlive()
{
    return !bDeleteMe && !bShuttingDown && bKitCommitted && Role == ROLE_Authority && WorldInfo.NetMode == NM_Standalone
        && Builder != None && !Builder.bDeleteMe && Builder.Health > 0
        && PC != None && PC.Pawn == Builder;
}

function bool HasCompleteKit()
{
    return IsOwnerAlive() && ConstructionPDA != None && !ConstructionPDA.bDeleteMe
        && DestructionPDA != None && !DestructionPDA.bDeleteMe
        && Toolbox != None && !Toolbox.bDeleteMe && Wrench != None && !Wrench.bDeleteMe
        && ConstructionPDA.Instigator == Builder && DestructionPDA.Instigator == Builder
        && Toolbox.Instigator == Builder && Wrench.Instigator == Builder;
}

function int AddMetal(int Amount)
{
    local int Before;
    if (!IsOwnerAlive() || Amount <= 0) return 0;
    Before = Metal;
    Metal = Min(class'VREngineerRules'.const.MetalCapacity, Metal + Amount);
    SyncMetalHUD();
    return Metal - Before;
}

function bool SpendMetal(int Amount)
{
    if (!IsOwnerAlive() || Amount < 0 || Metal < Amount) return false;
    Metal -= Amount;
    SyncMetalHUD();
    return true;
}

function SyncMetalHUD()
{
    if (ConstructionPDA != None) ConstructionPDA.AmmoCount[0] = Metal;
    if (DestructionPDA != None) DestructionPDA.AmmoCount[0] = Metal;
    if (Toolbox != None) Toolbox.AmmoCount[0] = Metal;
    if (Wrench != None) Wrench.AmmoCount[0] = Metal;
}

function bool CanSelect(VREngineerRules.EngineerBuildingSlot Slot)
{
    return IsOwnerAlive() && class'VREngineerRules'.static.SupportedSlot(Slot)
        && (Sentry == None || Sentry.bDeleteMe) && Metal >= class'VREngineerRules'.static.BuildCost(Slot);
}

function bool SelectBlueprint(VREngineerRules.EngineerBuildingSlot Slot)
{
    if (!CanSelect(Slot) || Toolbox == None || ConstructionPDA == None || !ConstructionPDA.CanUseSourceWeapon()) return false;
    if (!class'VREngineerVR'.static.SwitchTool(ConstructionPDA, Toolbox)) return false;
    SelectedBlueprint = Slot;
    bBlueprintSelected = true;
    Toolbox.PlacementYaw = 0;
    Toolbox.bPrimaryHeld = false;
    Toolbox.bSecondaryHeld = false;
    `log("KF2VR_ENGINEER action=blueprint slot=" $ int(Slot) @ "metal=" $ Metal);
    return true;
}

function CancelBlueprint()
{
    bBlueprintSelected = false;
    if (Toolbox != None) Toolbox.HidePreview();
}

function bool PlaceSentry()
{
    local VREngineerSentry NewSentry;
    local vector Point;
    local rotator Facing;
    local string Reason;
    if (!IsOwnerAlive() || Toolbox == None || !Toolbox.CanUseSourceWeapon() || !bBlueprintSelected
        || !CanSelect(SelectedBlueprint) || !Toolbox.FindPlacement(Point, Facing, Reason)) return false;
    // Spawn and validate before committing the debit. The authority reruns the
    // trace here; a green preview is never sufficient permission to build.
    NewSentry = Spawn(class'VREngineerSentry', self,, Point + vect(0,0,83.82), Facing);
    if (NewSentry == None) return false;
    if (!class'VREngineerVR'.static.SwitchTool(Toolbox, Wrench, true)) { NewSentry.Destroy(); return false; }
    if (!SpendMetal(class'VREngineerRules'.const.SentryCost)) { NewSentry.Destroy(); return false; }
    NewSentry.InitializeBuilding(self);
    Sentry = NewSentry;
    CancelBlueprint();
    `log("KF2VR_ENGINEER action=placed level=1 metal=" $ Metal @ "position=" $ Point);
    return true;
}

function bool DemolishSentry()
{
    if (!IsOwnerAlive() || DestructionPDA == None || !DestructionPDA.CanUseSourceWeapon()
        || Sentry == None || Sentry.bDeleteMe) return false;
    if (!class'VREngineerVR'.static.SwitchTool(DestructionPDA, Wrench, true)) return false;
    Sentry.BreakBuilding();
    return true;
}

simulated event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (!HasCompleteKit()) { Destroy(); return; }
    SyncMetalHUD();
    if (EngineerHUD == None && PC.MyHUD != None)
    {
        EngineerHUD = Spawn(class'VREngineerHUD', self);
        if (EngineerHUD != None)
        { EngineerHUD.Engineer = self; PC.MyHUD.AddPostRenderedActor(EngineerHUD); }
    }
}

simulated event Destroyed()
{
    bShuttingDown = true;
    CancelBlueprint();
    if (Sentry != None) Sentry.Destroy();
    if (EngineerHUD != None)
    {
        if (PC != None && PC.MyHUD != None) PC.MyHUD.RemovePostRenderedActor(EngineerHUD);
        EngineerHUD.Destroy();
    }
    if (EngineerInput != None) EngineerInput.Engineer = None;
    if (EngineerInput != None && PC != None) PC.Interactions.RemoveItem(EngineerInput);
    // Selling/removing the kit anchor or losing any component removes the
    // complete building kit. No orphaned toolbox/wrench remains selectable.
    if (Toolbox != None && !Toolbox.bDeleteMe) Toolbox.Destroy();
    if (Wrench != None && !Wrench.bDeleteMe) Wrench.Destroy();
    if (DestructionPDA != None && !DestructionPDA.bDeleteMe) DestructionPDA.Destroy();
    if (ConstructionPDA != None && !ConstructionPDA.bDeleteMe) ConstructionPDA.Destroy();
    Super.Destroyed();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    Metal=200
}
