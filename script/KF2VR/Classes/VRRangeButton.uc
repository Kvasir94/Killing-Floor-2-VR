// Range-only control, through the same authoritative Use path as trader pods.
class VRRangeButton extends Actor implements(KFInterface_Usable) placeable;
var() name Action;
var() string Argument;
var repnotify string Caption;
var VRRangeLabel Label;
var float NextUse, LastHandContact;
replication { if (Role == ROLE_Authority && bNetDirty) Caption; }
simulated function bool GetIsUsable(Pawn User)
{
    local vector Eye, Aim, Normal, Hit, Across;
    local float Denom, Distance;
    if(User == None || User.Health<=0 || VSizeSq(User.Location-Location)>Square(200.0)) return false;
    Eye=User.GetPawnViewLocation(); Aim=vector(User.GetViewRotation()); Normal=vector(Rotation);
    Denom=Aim Dot Normal; if(Abs(Denom)<0.01) return false;
    Distance=((Location-Eye) Dot Normal)/Denom;
    if(Distance<0 || Distance>220) return false;
    Hit=Eye+Aim*Distance-Location;
    Across=Normal Cross vect(0,0,1);
    return Abs(Hit Dot Across)<75 && Abs(Hit.Z)<30 && FastTrace(Eye,Location);
}
// Called only by the range game with its existing server-accepted tracking.
function TryHandPress(KFPawn_Human Human,vector Palm)
{
    local vector Normal,Across,Offset;
    local bool bEntered;
    local VRRangeDirector D;
    if(Role != ROLE_Authority || Human == None || Human.Health<=0) return;
    Normal=vector(Rotation); Across=Normal Cross vect(0,0,1); Offset=Palm-Location;
    if(Abs(Offset Dot Normal)>12 || Abs(Offset Dot Across)>65 || Abs(Offset.Z)>22
        || VSizeSq(Human.Location-Palm)>Square(250.0) || !FastTrace(Human.Location+vect(0,0,35),Palm)) return;
    bEntered=WorldInfo.TimeSeconds-LastHandContact>0.2;
    LastHandContact=WorldInfo.TimeSeconds;
    if(!bEntered || WorldInfo.TimeSeconds<NextUse) return;
    NextUse=WorldInfo.TimeSeconds+0.5;
    foreach WorldInfo.DynamicActors(class'VRRangeDirector',D) { D.Activate(self,Human); return; }
}
function int GetInteractionIndex(Pawn User) { return 0; }
function bool ActivateFor(Pawn User)
{
    local VRRangeDirector D;
    if (Role != ROLE_Authority || User == None || User.Health <= 0
        || WorldInfo.TimeSeconds < NextUse) return false;
    NextUse=WorldInfo.TimeSeconds+0.5;
    foreach WorldInfo.DynamicActors(class'VRRangeDirector',D) { D.Activate(self, KFPawn_Human(User)); return true; }
    return false;
}
function bool UsedBy(Pawn User)
{
    return GetIsUsable(User) && ActivateFor(User);
}
// Ballistic hits use the same server-owned action and cooldown as Use.
// The controls have no health and never consume ammunition or grant it locally.
event TakeDamage(int Damage, Controller InstigatedBy, vector HitLocation, vector Momentum,
    class<DamageType> DamageType, optional TraceHitInfo HitInfo, optional Actor DamageCauser)
{
    if (Damage > 0 && InstigatedBy != None) ActivateFor(InstigatedBy.Pawn);
}
event Trigger(Actor Other,Pawn EventInstigator) { UsedBy(EventInstigator); }
simulated event Tick(float DeltaTime)
{
    if(WorldInfo.NetMode == NM_DedicatedServer || Caption == "") return;
    if(Label == None) Label=Spawn(class'VRRangeLabel',self,,Location,Rotation);
    if(Label != None && Label.Caption != Caption)
    { Label.Caption=Caption; if(Label.Display != None) Label.Display.bNeedsUpdate=true; }
}
simulated event Destroyed() { if(Label != None) Label.Destroy(); Super.Destroyed(); }
defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bNetInitialRotation=true
    bAlwaysRelevant=true
    bHidden=false
    bCollideActors=true
    bBlockActors=false
    bProjTarget=true
    Begin Object Class=CylinderComponent Name=UseArea
        CollisionRadius=70
        CollisionHeight=24
        CollideActors=true
        BlockActors=false
        BlockZeroExtent=true
        BlockNonZeroExtent=false
    End Object
    CollisionComponent=UseArea
    Components.Add(UseArea)
}


