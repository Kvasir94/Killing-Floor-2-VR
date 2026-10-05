// Opt-in desktop gameplay receipts. Synthetic hand aim verifies script input;
// it does not establish headset tracking, stereo views, or visual parity.
class VRPortalReplay extends Actor;

var KFPawn_Human Human;
var KFPlayerController PC;
var VRWeap_PortalGun Gun;
var KFWeapon PreviousWeapon;
var VRPortalReplayWall Walls[2];
var VRPortalEndpoint Blue, Orange;
var VRPortalReplayTraveler Traveler;
var KFWeapon TestPistol;
var vector PreviousLocation, FixtureOrigin;
var rotator PreviousRotation;
var EPhysics PreviousPhysics;
var bool bPreviousDamageable, bDone, bFailed, bCleaned;
var float Elapsed, StageTime;
var int Stage, CheckIndex, PairSequence;

function StartReplay(KFPawn_Human P)
{
    local VRPortalMathChecks MathChecks;
    Human=P;
    if (P != None) PC=KFPlayerController(P.Controller);
    if (Human == None || PC == None || WorldInfo.NetMode != NM_Standalone) { Destroy(); return; }
    PreviousWeapon=KFWeapon(P.Weapon); PreviousLocation=P.Location; PreviousRotation=PC.Rotation;
    PreviousPhysics=P.Physics; bPreviousDamageable=P.bCanBeDamaged;
    FixtureOrigin=P.Location+vect(0,0,6000);
    Human.bCanBeDamaged=false;
    Human.SetPhysics(PHYS_None);
    if (!Human.SetLocation(FixtureOrigin+vect(0,0,700))) { Finish(false); return; }
    Walls[0]=Spawn(class'VRPortalReplayWall',self,,FixtureOrigin,,,true);
    Walls[1]=Spawn(class'VRPortalReplayWall',self,,FixtureOrigin+vect(0,1000,0),,,true);
    Gun=VRWeap_PortalGun(P.FindInventoryType(class'VRWeap_PortalGun'));
    if (Gun == None) Gun=VRWeap_PortalGun(P.InvManager.CreateInventory(class'VRWeap_PortalGun',true));
    `log("KF2VR_PORTAL_REPLAY rev=1 phase=begin");
    MathChecks = new class'VRPortalMathChecks';
    if (!Check('portal_math', MathChecks.Run() == 0, "compiled-transform-aperture-sweep-checks")) return;
    if (!Check('fixture_ready', Gun != None && Walls[0] != None && Walls[1] != None, "owned-collision-and-inventory")) return;
    PairSequence=Gun.NativePairSequence;
    P.InvManager.SetCurrentWeapon(Gun);
    // Desktop smoke view keeps a placed aperture on screen. Live headset
    // orientation remains owned by tracking during an optional VR run.
    if (!Gun.bPortalVRSession) PC.SetRotation(rot(-14000,0,0));
}

function bool Check(name CaseName, bool Passed, string Detail)
{
    `log("KF2VR_PORTAL_REPLAY rev=1 phase=check index=" $ CheckIndex @ "name=" $ CaseName
        @ "passed=" $ Passed @ "detail=" $ Detail);
    ++CheckIndex;
    if (!Passed) Finish(false);
    return Passed;
}

function AimAt(vector Target)
{
    Gun.TrackedOrigin=Human.GetPawnViewLocation();
    Gun.TrackedAim=rotator(Target-Gun.TrackedOrigin);
    Gun.bTrackedPose=true;
    Gun.LastTrackedInputTime=WorldInfo.TimeSeconds;
}

function Pulse(byte Mode)
{
    Gun.StopFire(Mode); Gun.StartFire(Mode); Gun.StopFire(Mode);
}

function Cleanup()
{
    local int I;
    if (bCleaned) return;
    bCleaned=true;
    if (Traveler != None) { Traveler.Destroy(); Traveler=None; }
    if (Gun != None) { Gun.CancelSourceInput(); Gun.ClearPortals(); }
    for (I=0; I<2; ++I) if (Walls[I] != None) { Walls[I].Destroy(); Walls[I]=None; }
    if (Human != None && !Human.bDeleteMe)
    {
        Human.bCanBeDamaged=bPreviousDamageable;
        Human.SetLocation(PreviousLocation); Human.SetPhysics(PreviousPhysics);
        if (PC != None) PC.SetRotation(PreviousRotation);
        if (PreviousWeapon != None && !PreviousWeapon.bDeleteMe) Human.InvManager.SetCurrentWeapon(PreviousWeapon);
    }
}

function Finish(bool Passed)
{
    if (bDone) return;
    bDone=true; bFailed=!Passed;
    Cleanup();
    `log("KF2VR_PORTAL_REPLAY rev=1 phase=complete checks=" $ CheckIndex @ "passed=" $ Passed);
}

event Tick(float DeltaTime)
{
    local vector ExitPosition, EntryPosition, BeforeVelocity;
    local VRPortalReplayTraveler ExitBlocker;
    local array<ImpactInfo> ShotHits;
    local int I;
    local float Penetration;
    local bool bHitThroughPortal;
    Super.Tick(DeltaTime);
    if (bDone || Human == None) return;
    Elapsed+=DeltaTime; StageTime+=DeltaTime;
    if (Elapsed>25) { Check('timeout',false,"replay-timeout"); return; }
    if (Gun == None || Human.Health<=0) { Check('owner_alive',false,"owner-or-gun-lost"); return; }
    if (!Gun.CanUseSourceWeapon() || StageTime<0.65) return;
    switch (Stage)
    {
    case 0:
        AimAt(FixtureOrigin); Pulse(0); Blue=Gun.Portals[0];
        if (!Check('blue_placement',Blue!=None && Gun.Portals[1]==None
            && Gun.NativePairFirst==None && Gun.NativePairSecond==None && Gun.NativePairSequence==PairSequence,
            "trigger-created-blue-only-native-idle")) return;
        break;
    case 1:
        AimAt(FixtureOrigin+vect(0,1000,0));
        Gun.SetIronSights(true); Gun.SetIronSights(false); Orange=Gun.Portals[1];
        if (!Check('orange_pair',Orange!=None && Gun.Portals[0]==Blue && Blue.OtherPortal==Orange
            && Orange.OtherPortal==Blue && Gun.NativePairFirst==Blue && Gun.NativePairSecond==Orange
            && Gun.NativePairSequence==PairSequence+1,"right-mouse-created-linked-orange-one-native-open")) return;
        PairSequence=Gun.NativePairSequence;
        // An immediate shot of the opposite color must honor shared recovery.
        AimAt(FixtureOrigin+vect(150,0,0)); Pulse(0);
        if (!Check('shared_cooldown',Gun.Portals[0]==Blue && Gun.ShotsFired==2,"rapid-opposite-color-rejected")) return;
        break;
    case 2:
        Walls[0].Tag='NoPortal'; AimAt(FixtureOrigin); Pulse(0); Walls[0].Tag='Portalable';
        if (!Check('invalid_preserves_pair',Gun.Portals[0]==Blue && Gun.Portals[1]==Orange
            && Blue.OtherPortal==Orange && Gun.NativePairSequence==PairSequence,
            "explicit-noportal-surface-rejected-no-native-transition")) return;
        break;
    case 3:
        AimAt(FixtureOrigin+vect(150,0,0)); Pulse(0);
        if (!Check('replace_one_color',Gun.Portals[0]!=None && Gun.Portals[0]!=Blue
            && Gun.Portals[1]==Orange && Orange.OtherPortal==Gun.Portals[0]
            && Gun.NativePairFirst==Gun.Portals[0] && Gun.NativePairSecond==Orange
            && Gun.NativePairSequence==PairSequence+2,"blue-replaced-orange-retained-native-close-then-open")) return;
        PairSequence=Gun.NativePairSequence;
        Blue=Gun.Portals[0];
        break;
    case 4:
        AimAt(FixtureOrigin+vect(0,1000,0)); Pulse(0);
        if (!Check('overlap_preserves_pair',Gun.Portals[0]==Blue && Gun.Portals[1]==Orange,"blue-cannot-overlap-orange")) return;
        TestPistol=KFWeapon(Human.FindInventoryType(class'KFWeap_Pistol_9mm'));
        if (TestPistol == None) TestPistol=KFWeapon(Human.InvManager.CreateInventory(class'KFWeap_Pistol_9mm',true));
        Traveler=Spawn(class'VRPortalReplayTraveler',self,,Orange.Location+vect(0,0,200),,,true);
        if (!Check('hitscan_ready',TestPistol!=None && Traveler!=None && Gun.HitscanBridge!=None,"stock-9mm-and-native-router")) return;
        Traveler.bCanBeDamaged=true;
        TestPistol.CalcWeaponFire(Blue.Location+vect(0,0,200),Blue.Location-vect(0,0,500),ShotHits);
        Penetration=TestPistol.GetInitialPenetrationPower(0);
        for (I=0; I<ShotHits.Length; ++I)
            if (ShotHits[I].HitActor == Traveler)
            {
                bHitThroughPortal=true;
                TestPistol.ProcessInstantHitEx(0,ShotHits[I],1,Penetration,I);
            }
        if (!Check('hitscan_through_portal',bHitThroughPortal && Traveler.Health<100
            && Gun.HitscanBridge.PortalSegments>0,"stock-ray-and-stock-damage-reached-exit-target")) return;
        Traveler.Destroy(); Traveler=None;
        break;
    case 5:
        Traveler=Spawn(class'VRPortalReplayTraveler',self,,Blue.Location+vect(0,0,48),,,true);
        if (!Check('traveler_ready',Traveler!=None,"owned-pawn-cylinder")) return;
        Traveler.Velocity=vect(0,0,-1000);
        Blue.ObserveTraveler(Traveler,0.016);
        ExitPosition=Traveler.Location;
        if (!Check('swept_traversal',Blue.TraversalCount==1 && VSize(Traveler.Location-Orange.Location)<50
            && Abs(VSize(Traveler.Velocity)-1000)<0.1 && Traveler.Velocity.Z>999,"pawn-sweep-preserved-speed-and-rotated-momentum")) return;
        Traveler.SetPhysics(PHYS_None);
        Orange.ObserveTraveler(Traveler,0.016);
        if (!Check('exit_lock',Orange.TraversalCount==0 && Traveler.Location==ExitPosition,"no-immediate-return-traversal")) return;
        EntryPosition=Blue.Location+vect(0,0,48);
        Traveler.SetLocation(EntryPosition); Traveler.Velocity=vect(0,0,-1000);
        BeforeVelocity=Traveler.Velocity;
        ExitBlocker=Spawn(class'VRPortalReplayTraveler',self,,ExitPosition,,,true);
        if (!Check('exit_blocker_ready',ExitBlocker!=None,"owned-occupancy-blocker")) return;
        if (!Check('blocked_exit',!Blue.Transfer(Traveler,Blue.Location) && Traveler.Location==EntryPosition
            && Traveler.Velocity==BeforeVelocity && Blue.BlockedExitCount>0,"occupied-destination-preserves-entry-state"))
        { ExitBlocker.Destroy(); return; }
        ExitBlocker.Destroy(); Traveler.Destroy(); Traveler=None;
        break;
    case 6:
        Gun.bPrimaryHeld=true; Gun.bSecondaryHeld=true; Gun.bTrackedPose=true;
        Gun.CancelSourceInput();
        if (!Check('cancel_input',!Gun.bPrimaryHeld && !Gun.bSecondaryHeld && !Gun.bTrackedPose,"tracking-loss-cancels-held-input")) return;
        Gun.ConsumeAmmo(0); Gun.ConsumeAmmo(1);
        if (!Check('infinite_ammo',Gun.HasAnyAmmo() && Gun.HasAmmo(0,100000) && Gun.HasAmmo(1,100000)
            && Gun.AmmoCount[0]==1 && Gun.AmmoCount[1]==1,"shots-never-consume-ammo")) return;
        Gun.ClearPortals();
        if (!Check('pair_cleanup',Gun.Portals[0]==None && Gun.Portals[1]==None
            && Gun.NativePairFirst==None && Gun.NativePairSecond==None && Gun.NativePairSequence==PairSequence+1,
            "both-endpoints-destroyed-one-native-close")) return;
        Finish(true); return;
    }
    ++Stage; StageTime=0;
}

event Destroyed() { Cleanup(); Super.Destroyed(); }

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}
