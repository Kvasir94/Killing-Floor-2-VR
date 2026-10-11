// One payload per pawn lifetime, including all detached parts of that pawn.
// No KF2VR reference: the core supplies exact authority-owned hand receipts.
class BreacherBodyCharge extends Actor;

var KFPawn_Monster Body;
var Controller Charger;
var repnotify float Charge;
var bool bSpent, bReserved, bObservedSplit;
var float NextRefresh;
// Canonical connected-piece root, not whichever hand happened to move last.
var name PayloadBone;

replication
{
    if (bNetDirty) Charge;
}

static function BreacherBodyCharge FindFor(KFPawn_Monster M)
{
    local BreacherBodyCharge C;
    if (M==None) return None;
    // Owner is installed before Spawn/PostBeginPlay callbacks can re-enter.
    // It reserves identity while a new ledger's Body field is initialized.
    foreach M.DynamicActors(class'BreacherBodyCharge',C)
        if ((C.Body==M || (C.Body==None && C.Owner==M)) && !C.bDeleteMe && !C.bPendingDelete) return C;
    return None;
}

static function bool Enabled(Pawn P)
{
    local BreacherPerk Perk;
    if (KFPawn(P)==None || P.bDeleteMe || P.bPendingDelete || P.Health<=0
        || P.Controller==None || P.Controller.Pawn!=P) return false;
    Perk=BreacherPerk(KFPawn(P).GetPerk());
    return Perk!=None && Perk.SkillActive(6);
}

// Find the nearest broken ancestor, exactly as connected body ownership does.
// An unknown bone is not eligible for a stored payload.
static function name Piece(KFPawn_Monster M, name Bone)
{
    local int I;
    local name Parent;
    if (M==None || M.Mesh==None || Bone=='' || M.Mesh.MatchRefBone(Bone)==INDEX_NONE) return '';
    for (I=0; I<256; ++I)
    {
        if (M.Mesh.IsBrokenConstraint(Bone)) return Bone;
        Parent=M.Mesh.GetParentBone(Bone);
        if (Parent=='' || Parent==Bone) return Bone;
        Bone=Parent;
    }
    return '';
}

static function bool PhysicalClaim(KFPawn_Monster M, Actor R)
{
    return M!=None && M.Mesh!=None && R!=None && R.IsA('VRGrabOwnership')
        && !R.bDeleteMe && !R.bPendingDelete && R.Owner==M && R.Instigator!=None
        && !R.Instigator.bDeleteMe && R.Instigator.Health>0 && R.Instigator.Controller!=None
        && R.Instigator.Controller.Pawn==R.Instigator
        && R.Tag!='' && M.Mesh.MatchRefBone(R.Tag)!=INDEX_NONE
        && !M.Mesh.IsBoneHidden(M.Mesh.MatchRefBone(R.Tag)) && Piece(M,R.Tag)!=''
        && !class'BreacherConsumedPiece'.static.IsConsumed(M,R.Tag);
}

static function bool ValidClaim(KFPawn_Monster M, Actor R)
{
    return PhysicalClaim(M,R) && Enabled(R.Instigator);
}

function bool SelectedPieceClaimed()
{
    local Actor R;
    foreach DynamicActors(class'Actor',R)
        if (PhysicalClaim(Body,R) && Piece(Body,R.Tag)==PayloadBone) return true;
    return false;
}

static function bool HasSplit(KFPawn_Monster M)
{
    local int I;
    if (M==None || M.Mesh==None || M.Mesh.PhysicsAsset==None) return false;
    for (I=0; I<Min(256,M.Mesh.PhysicsAsset.BodySetup.Length); ++I)
        if (M.Mesh.IsBrokenConstraint(M.Mesh.PhysicsAsset.BodySetup[I].BoneName)) return true;
    return false;
}

static function int HolderOrder(Pawn P)
{
    return (P!=None && P.PlayerReplicationInfo!=None) ? P.PlayerReplicationInfo.PlayerID : 2147483647;
}

static function Actor PayloadClaim(KFPawn_Monster M, Pawn P, optional name RequiredPiece, optional bool bHeldOnly)
{
    local Actor R, Best;
    local name Root, Part, BestPart;
    if (M==None || M.Mesh==None) return None;
    Root=M.Mesh.GetBoneName(0);
    foreach M.DynamicActors(class'Actor',R)
    {
        if (!ValidClaim(M,R) || (P!=None && R.Instigator!=P) || (bHeldOnly && R.bTearOff)) continue;
        Part=Piece(M,R.Tag);
        if (RequiredPiece!='' && Part!=RequiredPiece) continue;
        if (Best==None || (Best.bTearOff && !R.bTearOff)
            || (R.bTearOff==Best.bTearOff && ((Part==Root && BestPart!=Root)
                || ((Part==Root)==(BestPart==Root) && (HolderOrder(R.Instigator)<HolderOrder(Best.Instigator)
                    || (HolderOrder(R.Instigator)==HolderOrder(Best.Instigator) && R.DrawScale<Best.DrawScale))))))
        { Best=R; BestPart=Part; }
    }
    return Best;
}

// A first split resolves the original whole-body reservoir exactly once.
// Afterwards it remains with the component containing this canonical root,
// including later splits, drops and throws. Regripping a different fragment
// never moves energy to that fragment.
function bool RefreshPiece()
{
    local Actor Claim;
    if (Body==None || Body.Mesh==None || PayloadBone=='' || Body.Mesh.MatchRefBone(PayloadBone)==INDEX_NONE) return false;
    if (!bObservedSplit && HasSplit(Body))
    {
        bObservedSplit=true;
        // A retained torso receipt includes a deliberate throw. Do not move
        // its reservoir to a held alternate while the torso is in flight.
        // Even a catcher without DMS keeps physical custody of the torso; that
        // must not teleport its charge into another player's severed limb.
        if (!SelectedPieceClaimed())
        {
            Claim=PayloadClaim(Body,Instigator,'',true);
            if (Claim==None) Claim=PayloadClaim(Body,None,'',true);
            if (Claim!=None) PayloadBone=Piece(Body,Claim.Tag);
        }
    }
    // Broken constraints may temporarily disappear during mesh replacement.
    // Wait for the exact piece to return instead of silently joining it back.
    return !Body.Mesh.IsBoneHidden(Body.Mesh.MatchRefBone(PayloadBone))
        && Piece(Body,PayloadBone)==PayloadBone
        && !class'BreacherConsumedPiece'.static.IsConsumed(Body,PayloadBone);
}

// Prefer the existing living holder while they still hold this exact piece.
// A new eligible holder may take it from a thrown/dropped/dead player's state;
// this changes attribution, not stored energy or the one-shot body identity.
function Actor ResolveHolder()
{
    local Actor Claim;
    if (!RefreshPiece()) return None;
    if (Enabled(Instigator)) Claim=PayloadClaim(Body,Instigator,PayloadBone,true);
    if (Claim==None) Claim=PayloadClaim(Body,None,PayloadBone,true);
    if (Claim==None && Enabled(Instigator)) Claim=PayloadClaim(Body,Instigator,PayloadBone);
    if (Claim==None) Claim=PayloadClaim(Body,None,PayloadBone);
    if (Claim!=None)
    {
        Instigator=Claim.Instigator;
        Charger=Instigator.Controller;
        SetLocation(Claim.Location);
    }
    return Claim;
}

static function RecordDamage(KFPawn_Monster M, int Amount, Controller Attacker,
    class<DamageType> Kind, Actor Causer, optional name ContactBone, optional bool bCorpse)
{
    local Actor Claim;
    local BreacherBodyCharge C;
    local class<KFDamageType> KFDT;
    if (M==None || M.Mesh==None || M.WorldInfo.NetMode==NM_Client || M.Role!=ROLE_Authority
        || (bCorpse ? M.Health>0 : M.Health<=0) || M.IsABoss() || Amount<=0
        || Attacker==None || Attacker.Pawn==None || Causer==None || Kind==None
        || Kind.default.bCausedByWorld || ClassIsChildOf(Kind,class'BreacherStoredExplosion')
        || M.bTakingRadiusDamage || GameExplosionActor(Causer)!=None
        || Left(string(Kind),11)=="KF2Breacher" || InStr(string(Kind),"VRDT_")!=INDEX_NONE) return;
    // Both native paths require actual component/bone hit context; the live
    // path contributes authoritative post-adjustment NetDamage. Radius-on-bone
    // delivery is also excluded by the native context, not by its damage type.
    if (ContactBone=='' || Piece(M,ContactBone)==''
        || class'BreacherConsumedPiece'.static.IsConsumed(M,ContactBone)) return;
    KFDT=class<KFDamageType>(Kind);
    // A lingering DOT tick is not a new shield interception.
    if (KFDT!=None && KFDT.default.DoT_Type!=DOT_None) return;
    C=FindFor(M);
    if (C!=None)
    {
        if (C.bSpent || C.bReserved) return;
        Claim=C.ResolveHolder();
        if (Claim==None || Claim.bTearOff || Piece(M,ContactBone)!=C.PayloadBone) return;
    }
    else
        Claim=PayloadClaim(M,None,Piece(M,ContactBone),true);
    if (Claim==None || Claim.Instigator.Controller==Attacker
        || Claim.Instigator.GetTeamNum()==Attacker.GetTeamNum()) return;
    if (C==None)
    {
        C=M.Spawn(class'BreacherBodyCharge',M,,Claim.Location);
        if (C==None || C.bDeleteMe || C.bPendingDelete) return;
        if (M.bDeleteMe || !ValidClaim(M,Claim)) { C.Destroy(); return; }
        C.Body=M;
        C.Charger=Claim.Instigator.Controller;
        C.Instigator=Claim.Instigator;
        C.PayloadBone=Piece(M,Claim.Tag);
        C.bObservedSplit=HasSplit(M);
    }
    if (C.bSpent || C.bReserved || C.Instigator!=Claim.Instigator) return;
    C.Charge=FMin(300,C.Charge+Amount);
    C.bNetDirty=true;
    C.SetLocation(Claim.Location);
}

// Called only by the core's validated hard-contact path, never by collision.
// Other is its ownership receipt; normal carries actual closing speed.
event Touch(Actor Other, PrimitiveComponent OtherComp, vector HitLocation, vector HitNormal)
{
    local Actor Chosen;
    local BreacherChargeBurst Burst;
    local float Energy;
    if (Role!=ROLE_Authority || WorldInfo.NetMode==NM_Client || bSpent || bReserved || Charge<1
        || Body==None || Body.bDeleteMe || !ValidClaim(Body,Other)
        || !(VSize(HitNormal)>=220 && VSize(HitNormal)<=2201)) return;
    Chosen=ResolveHolder();
    if (Chosen==None || Other.Instigator!=Instigator || Piece(Body,Other.Tag)!=PayloadBone
        || Charger==None || Charger.Pawn!=Instigator
        || !(VSizeSq(HitLocation-Instigator.Location)<=Square(2400))) return;
    Energy=Charge;
    // Reserve before Spawn (which can invoke arbitrary mutator callbacks),
    // but only commit once an inert burst exists. Spawn failure loses nothing.
    bReserved=true;
    Burst=Spawn(class'BreacherChargeBurst',self,,HitLocation);
    if (Burst==None || Burst.bDeleteMe)
    { bReserved=false; return; }
    // Recheck identity after spawn callbacks before committing any damage.
    if (Body==None || Body.bDeleteMe || Charger==None || Charger.Pawn!=Instigator || !Enabled(Instigator))
    { Burst.Destroy(); bReserved=false; return; }
    Charge=0;
    bSpent=true;
    bNetDirty=true;
    Burst.Detonate(Charger,Body,Energy,50+75*Energy/300,class'BreacherDMSDamage',PayloadBone);
    // No callback can restore charge after a burst has begun applying damage.
    if (!Burst.bReady) { Charge=Energy; bSpent=false; if (!Burst.bDeleteMe) Burst.Destroy(); }
    bReserved=false;
}

event Tick(float Delta)
{
    if (Role!=ROLE_Authority) return;
    if (Body==None || Body.bDeleteMe || Body.bPendingDelete)
    { Destroy(); return; }
    // Keep spent tombstones for the ORIGINAL body lifetime, independently of
    // player death/respawn. Its surviving pieces cannot create another ledger.
    if (!bSpent && !bReserved && WorldInfo.TimeSeconds>=NextRefresh)
    {
        NextRefresh=WorldInfo.TimeSeconds+0.1;
        ResolveHolder();
    }
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
