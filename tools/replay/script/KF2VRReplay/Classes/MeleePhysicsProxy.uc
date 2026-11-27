// Experiment (#227, docs/re/MELEE_PHYSICS_PATH.md): the rigid body that stands
// in for a held melee weapon. It is the weapon's stock dropped-pickup mesh,
// which stock already simulates, with gravity cancelled and contact reports on.
// Each contact the engine reports is logged; nothing here deals damage.
class MeleePhysicsProxy extends KActorSpawnable;

var MeleePhysicsProbe Probe;
var int Contacts;
var bool bShelf;

simulated event RigidBodyCollision(PrimitiveComponent HitComponent, PrimitiveComponent OtherComponent,
    const out CollisionImpactData RigidCollisionData, int ContactIndex)
{
    local RigidBodyContactInfo C;
    local string Other;
    local int Mine;
    ++Contacts;
    if (RigidCollisionData.ContactInfos.Length == 0) return;
    C = RigidCollisionData.ContactInfos[0];
    Mine = Clamp(ContactIndex, 0, 1);
    Other = (OtherComponent != None && OtherComponent.Owner != None) ? string(OtherComponent.Owner.Class.Name) : "none";
    `log("KF2VR_PHYSPROBE kind=contact" $ (bShelf ? "-shelf" : "") @ "other=" $ Other @ "points=" $ RigidCollisionData.ContactInfos.Length
        @ "pos=" $ C.ContactPosition @ "pen=" $ C.ContactPenetration
        @ "speed_mine=" $ int(VSize(C.ContactVelocity[Mine])) @ "speed_other=" $ int(VSize(C.ContactVelocity[1 - Mine]))
        @ "force=" $ int(VSize(RigidCollisionData.TotalNormalForceVector))
        @ "lag=" $ (Probe != None ? Probe.CurrentLag() : -1.0));
    if (Probe != None) Probe.NoteContact(OtherComponent);
}

defaultproperties
{
    bCollideWorld=false
    bBlockActors=false
    bProjTarget=false
    bBlocksNavigation=false
    bBlocksTeleport=false
    RemoteRole=ROLE_None
    bNeedsRBStateReplication=false
    bDamageAppliesImpulse=false
}
