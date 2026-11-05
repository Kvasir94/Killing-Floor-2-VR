// Real stock weapon pickups: production VRStockWorldPickup performs the grab.
class VRRangeRack extends KFPickupFactory_Item;
var repnotify class<KFWeapon> RangeWeapon;
var VRRangeLabel Label;
replication { if(Role == ROLE_Authority && bNetDirty) RangeWeapon; }
simulated function Configure(class<KFWeapon> W)
{
    RangeWeapon=W;
    ItemPickups.Length=1; ItemPickups[0].ItemClass=W; ItemPickups[0].Priority=1;
    PickupIndex=0; SetPickupMesh(); bNetDirty=true;
}
simulated event ReplicatedEvent(name PropertyName)
{
    if(PropertyName == 'RangeWeapon') Configure(RangeWeapon);
    else Super.ReplicatedEvent(PropertyName);
}
simulated event Tick(float DeltaTime)
{
    local vector At;
    local rotator Facing;
    Super.Tick(DeltaTime);
    if(WorldInfo.NetMode == NM_DedicatedServer || RangeWeapon == None) return;
    if(Label == None)
    {
        At=Location+vector(Rotation)*40+vect(0,0,-32);
        Facing=Rotation; Facing.Yaw+=32768;
        Label=Spawn(class'VRRangeLabel',self,,At,Facing);
        if(Label != None) { Label.Caption=RangeWeapon.default.ItemName; Label.bShowHint=false; }
    }
}
simulated event Destroyed()
{
    if(Label != None) Label.Destroy();
    Super.Destroyed();
}
defaultproperties
{
    bStatic=false
    bNoDelete=false
    bAlwaysRelevant=true
    RemoteRole=ROLE_SimulatedProxy
    bKismetDriven=true
    bEnabledAtStart=true
    bUseRespawnTimeOverride=true
    RespawnTime=3.0
    Begin Object Name=StaticMeshComponent0
        Translation=(Z=0)
    End Object
    ItemPickups.Empty
}



