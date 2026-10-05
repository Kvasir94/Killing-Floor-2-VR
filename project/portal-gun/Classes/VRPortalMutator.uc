// Local playable entry: grant once per spawned pawn after the ordinary demo
// has initialized its hands bridge. No replay, artificial pose or movement.
class VRPortalMutator extends KFMutator;

var KFPawn_Human GrantedPawn;

simulated function PostBeginPlay()
{
    Super.PostBeginPlay();
    if (WorldInfo.NetMode == NM_Standalone && Role == ROLE_Authority)
        SetTimer(0.25, true, 'GrantPortalGun');
}

function GrantPortalGun()
{
    local KFPlayerController PC;
    local KFPawn_Human Human;
    local VRWeap_PortalGun Gun;
    local VRHandsBridge Bridge;
    local bool bBridgeReady;
    local KFGameReplicationInfo GRI;

    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI == None || !GRI.bMatchHasBegun || GRI.bMatchIsOver) return;
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        Human = KFPawn_Human(PC.Pawn);
        if (!PC.IsLocalController() || Human == None || Human.Health <= 0
            || KFPawn_Customization(Human) != None || Human.InvManager == None
            || Human.Weapon == None || Human == GrantedPawn) continue;
        foreach WorldInfo.AllActors(class'VRHandsBridge', Bridge)
            if (Bridge.PC == PC && !Bridge.bDeleteMe) { bBridgeReady = true; break; }
        if (!bBridgeReady) return;
        Gun = VRWeap_PortalGun(Human.FindInventoryType(class'VRWeap_PortalGun'));
        if (Gun == None)
            Gun = VRWeap_PortalGun(Human.InvManager.CreateInventory(class'VRWeap_PortalGun', true));
        if (Gun == None) return;
        Gun.bGivenAtStart = true;
        Human.InvManager.SetCurrentWeapon(Gun);
        GrantedPawn = Human;
        `log("KF2VR_PORTAL_PLAYABLE phase=granted pawn=" $ Human @ "weapon=" $ Gun.Class);
        return;
    }
}

defaultproperties
{
    RemoteRole=ROLE_None
}
