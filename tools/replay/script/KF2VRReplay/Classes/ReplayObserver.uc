// Initial scenario setup and observations only. Native replay owns all inputs;
// normal VRHandsBridge.Tick owns all inventory and weapon updates.
class ReplayObserver extends KFMutator;
var VRDemo Demo;
var VRHandsBridge B;
var KFWeapon Guns[2];
var int InitialReserve[2], Shots[2], Reloads[2], PreviousAmmo[2];
var bool Ready, BaselineReady;
var float Started, LastNote;
function KFWeapon FindWeapon(class<KFWeapon> C)
{
    local Inventory I;
    for (I=B.Human.InvManager.InventoryChain; I!=None; I=I.Inventory)
        if (I.Class==C) return KFWeapon(I);
    return None;
}
simulated event Tick(float DT)
{
    local VRDemo D;
    local int H;
    if (Demo==None) foreach WorldInfo.AllActors(class'VRDemo',D) { Demo=D; break; }
    if (Demo==None || Demo.HandsBridge==None || Demo.StarterLoadout==None) return;
    B=Demo.HandsBridge;
    if (B.Human==None || B.HandInventory==None || B.HandInventory.Input==None
        || Demo.StarterLoadout.NextDefinition<Demo.StarterLoadout.Definitions.Length) return;
    if (!Ready)
    {
        // Declared initial state: stock fallback reload, toggle carry, both hands.
        // Draw uses the normal inventory API; no ammo or reload-state assignment.
        B.bInteractiveReloads=false; B.bToggleGrip=true;
        Guns[0]=FindWeapon(class'KFWeap_GrenadeLauncher_HX25');
        Guns[1]=FindWeapon(class'KFWeap_GrenadeLauncher_M79');
        if (Guns[0]==None || Guns[1]==None) return;
        B.HandInventory.ReleaseHand(0); B.HandInventory.ReleaseHand(1);
        if (!B.HandInventory.Draw(0,Guns[0]) || !B.HandInventory.Draw(1,Guns[1])) return;
        for (H=0;H<2;++H) { PreviousAmmo[H]=Guns[H].AmmoCount[0]; }
        Started=WorldInfo.RealTimeSeconds; Ready=true;
        `log("KF2VR_INPUT_OBSERVER ready=True setup=stock-fallback bothHands=True inputWrites=False extraInventoryUpdates=False");
    }
    // Demo grants/perk capacity settle after equip. Measure only after both
    // weapons are active, before the first tape press; never alter their ammo.
    if (!BaselineReady && WorldInfo.RealTimeSeconds-Started>1.0
        && Guns[0].IsInState('Active') && Guns[1].IsInState('Active')) {
        BaselineReady=true;
        for(H=0;H<2;++H) {
            InitialReserve[H]=Guns[H].SpareAmmoCount[0];
            `log("KF2VR_INPUT_OBSERVER baseline hand=" $ H @ "reserve=" $ InitialReserve[H]);
        }
    }
    for (H=0;H<2;++H)
    {
        if (Guns[H].AmmoCount[0]<PreviousAmmo[H]) {
            ++Shots[H];
            `log("KF2VR_INPUT_OBSERVER event=ammo-consumed hand=" $ H @ "weapon=" $ Guns[H].Class @ "state=" $ Guns[H].GetStateName());
        }
        if (Guns[H].AmmoCount[0]>PreviousAmmo[H]) {
            ++Reloads[H];
            `log("KF2VR_INPUT_OBSERVER event=ammo-loaded hand=" $ H @ "weapon=" $ Guns[H].Class @ "reserve=" $ Guns[H].SpareAmmoCount[0]);
        }
        PreviousAmmo[H]=Guns[H].AmmoCount[0];
    }
    if (WorldInfo.RealTimeSeconds-LastNote>0.1)
    {
        LastNote=WorldInfo.RealTimeSeconds;
        for(H=0;H<2;++H)
            `log("KF2VR_INPUT_OBSERVER hand=" $ H @ "weapon=" $ Guns[H].Class @ "state=" $ Guns[H].GetStateName()
                @ "ammo=" $ Guns[H].AmmoCount[0] @ "reserve=" $ Guns[H].SpareAmmoCount[0]
                @ "armed=" $ B.Hands[H].bTriggerArmed @ "valid=" $ B.NativeValidMask
                @ "trigger=" $ B.NativeTriggerMask @ "active=" $ B.NativeTriggerActiveMask
                @ "shots=" $ Shots[H] @ "reloads=" $ Reloads[H]);
    }
    if (Shots[0]>=2 && Shots[1]>=2 && Reloads[0]>=2 && Reloads[1]>=2
        && Guns[0].AmmoCount[0]==1 && Guns[1].AmmoCount[0]==1) {
        if (!BaselineReady || InitialReserve[0]-Guns[0].SpareAmmoCount[0]!=Reloads[0]
            || InitialReserve[1]-Guns[1].SpareAmmoCount[0]!=Reloads[1]) {
            `log("KF2VR_INPUT_OBSERVER complete=False reason=reserve-conservation");
        } else {
            `log("KF2VR_INPUT_OBSERVER complete=True stockFallback=True conserved=True headsetAccepted=False");
        }
        Demo.DemoController.ConsoleCommand("quit");
    }
    if (WorldInfo.RealTimeSeconds-Started>90) {
        `log("KF2VR_INPUT_OBSERVER complete=False reason=timeout");
        Demo.DemoController.ConsoleCommand("quit");
    }
}
defaultproperties
{
    RemoteRole=ROLE_None
    TickGroup=TG_PostUpdateWork
}

