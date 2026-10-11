// Optional perk adapter: KF2Breacher compiles against stock packages only.
// Bump records a validated physical impulse; Touch spends kinetic pressure.
// Touch resets DrawScale to one even when refused; its result is bounded 1..2.
class VRBreacherPhysics extends Object;

static simulated function Actor PressureActor(Controller C)
{
    local Actor A;
    if (C == None) return None;
    foreach C.DynamicActors(class'Actor', A)
        if (A.Class.Name == 'BreacherOverpressure' && A.Owner == C && !A.bDeleteMe) return A;
    return None;
}

static simulated function bool Selected(Controller C)
{
    local KFPlayerController PC;
    PC = KFPlayerController(C);
    return PC != None && PC.Pawn != None && PC.Pawn.Health > 0
        && PC.CurrentPerk != None && PC.CurrentPerk.Class.Name == 'BreacherPerk'
        && PC.CurrentPerk.PerkSkills.Length > 9 && PC.CurrentPerk.PerkSkills[9].bActive
        && PC.CurrentPerk.IsPerkLevelAllowed(9);
}

static simulated function bool ExpandedGrab(Controller C)
{
    if (!Selected(C)) return false;
    if (C.WorldInfo.TimeDilation < 1.0) return true;
    return StoredPressure(C) >= 40.0;
}

// UnTouch is a read-only pressure query: the optional actor writes the reply
// to stock DrawScale. This avoids inaccessible custom fields/dependencies.
static simulated function float StoredPressure(Controller C)
{
    local Actor A;
    A=PressureActor(C);
    if (A==None) return 0;
    A.UnTouch(C.Pawn);
    return FClamp((A.DrawScale-1)*100,0,100);
}

static simulated function bool Boss(KFPawn_Monster M)
{
    return M == None || M.IsABoss() || KFPawn_MonsterBoss(M) != None || KFInterface_MonsterBoss(M) != None;
}

static function float Spend(Controller C, Actor Target, vector Point, vector Impulse)
{
    local Actor A;
    if (C == None || C.Role != ROLE_Authority || !Selected(C)) return 1;
    A = PressureActor(C);
    if (A == None) return 1;
    A.Touch(Target, None, Point, Impulse);
    return FClamp(A.DrawScale, 1, 2);
}

static function EmpowerPunch(Controller C, KFPawn Target, vector Point, name Bone,
    out int Damage, out vector Momentum, out class<DamageType> HitType)
{
    local float Scale;
    local bool bHeadStun;
    if (C == None || C.Role != ROLE_Authority || Target == None) return;
    bHeadStun = Selected(C) && StoredPressure(C) >= 40 && !Boss(KFPawn_Monster(Target))
        && Target.HitZones.Find('ZoneName', Bone) == HZI_HEAD;
    Scale = Spend(C, Target, Point, Momentum);
    if (Scale <= 1) return;
    Damage = Max(Damage, Min(600, Round(Damage * Scale)));
    Momentum = Normal(Momentum) * FMax(VSize(Momentum), FMin(VSize(Momentum) * Scale, 3500));
    if (bHeadStun)
    {
        if (HitType == class'VRDT_GloveCharged') HitType = class'VRDT_PressureGloveCharged';
        else if (HitType == class'VRDT_ChargedFist') HitType = class'VRDT_PressureChargedFist';
        else if (HitType != class'VRDT_GloveChargedStun') HitType = class'VRDT_ChargedFistStun';
    }
}

static function vector EmpowerThrow(Controller C, Actor Target, vector Point, vector Velocity)
{
    local float Scale;
    if (VSize(Velocity) < class'VRZedGrab'.default.MinThrowSpeed) return Velocity;
    Scale = Spend(C, Target, Point, Velocity);
    return Normal(Velocity) * FMin(VSize(Velocity) * Scale, class'VRZedGrab'.default.MaxThrowSpeed);
}

// Record only an actual validated physical contact; no per-frame velocity sampling.
static function NotifyImpact(Controller C, Actor Other, vector Impulse)
{
    local Actor A;
    if (C == None || C.Role != ROLE_Authority) return;
    A=PressureActor(C);
    if (A!=None) A.Bump(Other,None,Impulse);
}

static function NotifyPileDriver(Controller C, KFPawn Source, KFPawn Victim, vector Point, vector Direction, float BaseDamage)
{
    local Actor A;
    local class<Actor> Loaded;
    local KFPlayerController PC;
    if (C==None || C.Role!=ROLE_Authority || Source==None || Victim==None) return;
    PC=KFPlayerController(C);
    if (PC==None || PC.CurrentPerk==None || PC.CurrentPerk.Class.Name!='BreacherPerk'
        || PC.CurrentPerk.PerkSkills.Length<=2 || !PC.CurrentPerk.PerkSkills[2].bActive
        || !PC.CurrentPerk.IsPerkLevelAllowed(2)) return;
    foreach C.DynamicActors(class'Actor', A)
        if (A.Class.Name=='BreacherPileDriver' && A.Owner==C.Pawn)
        { A.Touch(Victim,Source.Mesh,Point,Normal(Direction)*BaseDamage); return; }
    Loaded=class<Actor>(DynamicLoadObject("KF2Breacher.BreacherPileDriver",class'Class',true));
    if (Loaded!=None)
    {
        A=C.Pawn.Spawn(Loaded,C.Pawn,,C.Pawn.Location);
        if (A!=None) A.Touch(Victim,Source.Mesh,Point,Normal(Direction)*BaseDamage);
    }
}
