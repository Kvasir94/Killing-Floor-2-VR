// One purchase owns the four building tools. The optional Wrangler has its
// own trader definition and never participates in this kit transaction.
class VREngineerKit extends Object;

static function VREngineerState Grant(VREngineerPDA PDA, KFPlayerController PC)
{
    local VREngineerState StateOwner;
    local KFInventoryManager Manager;
    if (PDA == None || PC == None || PC.Pawn == None || PC.Pawn.Health <= 0
        || PC.WorldInfo.NetMode != NM_Standalone) return None;
    Manager = KFInventoryManager(PC.Pawn.InvManager);
    if (Manager == None) return None;
    if (PDA.Engineer != None && PDA.Engineer.HasCompleteKit()) return PDA.Engineer;
    if (!class'VREngineerPresentation'.static.HasCoreAssets()) return None;
    // No adopting unrelated objects or adding duplicate kit components. This
    // also makes repeated grants idempotent without resetting metal/buildings.
    if (PC.Pawn.FindInventoryType(class'VREngineerToolbox') != None
        || PC.Pawn.FindInventoryType(class'VREngineerWrench') != None
        || PC.Pawn.FindInventoryType(class'VREngineerDestroyPDA') != None) return None;
    StateOwner = PC.Spawn(class'VREngineerState', PC);
    if (StateOwner == None) return None;
    StateOwner.Builder = KFPawn_Human(PC.Pawn);
    StateOwner.PC = PC;
    StateOwner.Toolbox = VREngineerToolbox(Manager.CreateInventory(class'VREngineerToolbox', true));
    StateOwner.Wrench = VREngineerWrench(Manager.CreateInventory(class'VREngineerWrench', true));
    StateOwner.DestructionPDA = VREngineerDestroyPDA(Manager.CreateInventory(class'VREngineerDestroyPDA', true));
    if (StateOwner.Toolbox == None || StateOwner.Wrench == None || StateOwner.DestructionPDA == None)
    { StateOwner.Destroy(); return None; }
    StateOwner.EngineerInput = new(PC) class'VREngineerInput';
    if (StateOwner.EngineerInput == None) { StateOwner.Destroy(); return None; }
    StateOwner.ConstructionPDA = PDA;
    PDA.Engineer = StateOwner;
    StateOwner.Toolbox.Engineer = StateOwner;
    StateOwner.Wrench.Engineer = StateOwner;
    StateOwner.DestructionPDA.Engineer = StateOwner;
    StateOwner.EngineerInput.Engineer = StateOwner;
    PC.Interactions.InsertItem(0, StateOwner.EngineerInput);
    StateOwner.bKitCommitted = true;
    StateOwner.SyncMetalHUD();
    class'VREngineerVR'.static.RegisterOwner(PC.Pawn);
    StateOwner.Toolbox.Class.static.TriggerAsyncContentLoad(StateOwner.Toolbox.Class);
    StateOwner.Wrench.Class.static.TriggerAsyncContentLoad(StateOwner.Wrench.Class);
    StateOwner.DestructionPDA.Class.static.TriggerAsyncContentLoad(StateOwner.DestructionPDA.Class);
    `log("KF2VR_ENGINEER action=kit-ready components=4 metal=" $ StateOwner.Metal);
    return StateOwner;
}

static function bool OwnsOnlyOneOfEach(KFPawn_Human P)
{
    local VREngineerWeapon W;
    local int PDAs, DestroyPDAs, Toolboxes, Wrenches;
    if (P == None || P.InvManager == None) return false;
    foreach P.InvManager.InventoryActors(class'VREngineerWeapon', W)
    {
        if (W.Class == class'VREngineerPDA') ++PDAs;
        if (W.Class == class'VREngineerDestroyPDA') ++DestroyPDAs;
        if (W.Class == class'VREngineerToolbox') ++Toolboxes;
        if (W.Class == class'VREngineerWrench') ++Wrenches;
    }
    return PDAs == 1 && DestroyPDAs == 1 && Toolboxes == 1 && Wrenches == 1;
}
