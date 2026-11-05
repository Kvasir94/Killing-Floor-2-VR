// Asset-only carry sampling for hip/slam magazine ejections. Every component
// is private, at identity and notify-free; no live reload or gun pose is bound.
class VRMagazineCarryRecipe extends Object;

// A loaded stripper clip is recoverable ammunition, not a removable magazine
// well. Sample its original loading wrist without opting the rifle into the
// detachable-magazine removal or insertion transaction.
function bool SampleStripper(VRHandsBridge Bridge, KFWeapon W, out name Anim,
    out name Track, out float Time, out int StockHand)
{
    local VRActionPath Ref;
    local VRReloadRigSampler Sampler;
    local float EndTime;
    local vector Seat, P, HandP;
    local quat Q, HandQ;
    local bool Ready;
    if (Bridge == None || W == None || W.MySkelMesh == None) return false;
    Ref = new(self) class'VRActionPath';
    if (!Ref.PrepareRef(Bridge, W, 'RW_Weapon')) return false;
    Anim = 'Reload_Empty'; Track = 'RW_StripMag'; StockHand = 1;
    Bridge.AttachComponent(Ref.Ref);
    Ref.RefSeq.SetAnim(Anim);
    if (Ref.RefSeq.AnimSeq != None && Ref.Ref.MatchRefBone(Track) >= 0)
    {
        EndTime = FClamp(W.MySkelMesh.GetReloadAmmoTime(Anim) * Ref.RefSeq.AnimSeq.RateScale,
            0, Ref.RefSeq.AnimSeq.SequenceLength);
        Ref.PoseRef(EndTime); Ref.RefRelative(Track, Seat, Q);
        while (EndTime > 1.0 / 60.0)
        {
            Ref.PoseRef(EndTime - 1.0 / 60.0); Ref.RefRelative(Track, P, Q);
            if (VSize(P - Seat) > 0.2) break;
            EndTime -= 1.0 / 60.0;
        }
        Sampler = new(self) class'VRReloadRigSampler';
        Ready = Sampler.FindCarryGrip(Ref.Ref, Ref.RefSeq, 'RW_Weapon', Track, Bridge.HandBone(StockHand),
            FMax(0, EndTime - class'VRInteractiveReload'.default.EntryLead * Ref.RefSeq.AnimSeq.RateScale),
            EndTime, Time, P, Q, HandP, HandQ);
    }
    Bridge.DetachComponent(Ref.Ref);
    return Ready;
}

// The cylinders that leave the gun whole: the 1858's under its lever, and the
// Spitfire's and Winterbite's from the broken-open frame (R38). Not the
// Rhino's, which swings out on its crane (R45).
static function bool RecoverableCylinderClass(class<KFWeapon> W)
{
    local class<KFWeapon> Profile;
    Profile = class'VRBreakCatalog'.static.ProfileClass(W);
    return W != None && (Profile == class'KFWeap_Revolver_Rem1858'
        || Profile == class'KFWeap_Pistol_Flare' || Profile == class'KFWeap_Pistol_HRGWinterbite');
}

static function bool RecoverableCylinder(KFWeapon W)
{
    return W != None && !W.bDeleteMe && RecoverableCylinderClass(W.Class);
}

// Sample the original cylinder insertion contact, never a generic fist.
function bool SampleCylinder(VRHandsBridge Bridge, KFWeapon W, out name Anim,
    out name Track, out float Time, out int StockHand)
{
    local VRActionPath Ref;
    local VRReloadRigSampler Sampler;
    local float EndTime;
    local vector P, HandP;
    local quat Q, HandQ;
    local bool Ready;
    if (Bridge == None || W == None || W.MySkelMesh == None) return false;
    Ref = new(self) class'VRActionPath';
    if (!Ref.PrepareRef(Bridge, W, 'RW_Weapon')) return false;
    Anim = 'Reload_Empty'; Track = 'RW_Cylinder'; StockHand = 1;
    Bridge.AttachComponent(Ref.Ref);
    Ref.RefSeq.SetAnim(Anim);
    if (Ref.RefSeq.AnimSeq != None && Ref.Ref.MatchRefBone(Track) >= 0)
    {
        EndTime = FClamp(W.MySkelMesh.GetReloadAmmoTime(Anim) * Ref.RefSeq.AnimSeq.RateScale,
            0, Ref.RefSeq.AnimSeq.SequenceLength);
        // The break-open guns carry the cylinder in whichever stock wrist
        // seats it, as their fresh-cylinder insert chooses (CylinderInsertHand).
        if (class'VRBreakCatalog'.static.ProfileClass(W.Class) != class'KFWeap_Revolver_Rem1858')
        {
            Ref.PoseRef(EndTime);
            if (VSize(Ref.Ref.GetBoneLocation(Bridge.HandBone(0)) - Ref.Ref.GetBoneLocation(Track))
                < VSize(Ref.Ref.GetBoneLocation(Bridge.HandBone(1)) - Ref.Ref.GetBoneLocation(Track)))
                StockHand = 0;
        }
        Sampler = new(self) class'VRReloadRigSampler';
        Ready = Sampler.FindCarryGrip(Ref.Ref, Ref.RefSeq, 'RW_Weapon', Track, Bridge.HandBone(StockHand),
            FMax(0, EndTime - class'VRInteractiveReload'.default.EntryLead * Ref.RefSeq.AnimSeq.RateScale),
            EndTime, Time, P, Q, HandP, HandQ);
    }
    Bridge.DetachComponent(Ref.Ref);
    return Ready;
}

// Recovery is an ammo-payload capability, independent of detachable wells.
static function bool RecoveryClass(class<KFWeapon> W)
{
    return W != None
        && (class'VRReloadCatalog'.static.FindClass(W) >= 0
            || class'VRBreakCatalog'.static.FindClass(W) >= 0 || class'VRPumpCatalog'.static.FindClass(W) >= 0);
}

static function bool WholeLoad(KFWeapon W)
{
    local int I;
    if (W == None || W.bDeleteMe) return false;
    I = class'VRBreakCatalog'.static.FindClass(W.Class);
    if (I >= 0) return class'VRBreakCatalog'.default.Profiles[I].DropBone != '';
    I = class'VRReloadCatalog'.static.FindClass(W.Class);
    return I >= 0 && RecoveryClass(W.Class) && !class'VRReloadCatalog'.default.Profiles[I].bNoEject
        && !class'VRReloadCatalog'.default.Profiles[I].bParkedLoaded;
}

// Find the original carrying contact directly. Unlike removable magazines,
// a loose tank/box/shell has no charging-handle or seating-policy preflight.
function bool SampleRecovery(VRHandsBridge Bridge, KFWeapon W, out name Anim,
    out name Track, out float Time, out int StockHand)
{
    local VRActionPath Ref;
    local VRReloadRigSampler Sampler;
    local int I;
    local name Root, OtherTrack;
    local float EndTime;
    local vector P, HandP;
    local quat Q, HandQ;
    local bool Ready;
    if (Bridge == None || W == None || W.MySkelMesh == None || !RecoveryClass(W.Class)) return false;
    Root = 'RW_Weapon'; Anim = 'Reload_Empty'; StockHand = 0;
    I = class'VRReloadCatalog'.static.FindClass(W.Class);
    if (I >= 0)
    {
        Track = class'VRReloadCatalog'.static.MagazineBone(I, true);
        OtherTrack = class'VRReloadCatalog'.static.MagazineBone(I, false);
        StockHand = class'VRReloadCatalog'.default.Profiles[I].InsertHand;
        if (W.Class == class'KFWeap_Bow_CompoundBow') Root = 'LW_Weapon';
    }
    else
    {
        I = class'VRBreakCatalog'.static.FindClass(W.Class);
        if (I >= 0)
        {
            Track = class'VRBreakCatalog'.default.Profiles[I].ClipBone;
            if (Track == '') Track = class'VRBreakCatalog'.default.Profiles[I].ShellBones[0];
            StockHand = class'VRBreakCatalog'.default.Profiles[I].InsertHand;
        }
        else
        {
            I = class'VRPumpCatalog'.static.FindClass(W.Class);
            if (I < 0) return false;
            Anim = class'VRPumpCatalog'.default.Profiles[I].EmptyInsertClip;
            if (Anim == '') Anim = 'Reload_Insert';
            Track = class'VRPumpCatalog'.default.Profiles[I].InsertTrack;
            StockHand = class'VRPumpCatalog'.default.Profiles[I].InsertHand;
        }
    }
    Ref = new(self) class'VRActionPath';
    if (!Ref.PrepareRef(Bridge, W, Root)) return false;
    Bridge.AttachComponent(Ref.Ref); Ref.RefSeq.SetAnim(Anim);
    if (Ref.RefSeq.AnimSeq != None && StockHand >= 0 && StockHand <= 1)
    {
        EndTime = FClamp(W.MySkelMesh.GetReloadAmmoTime(Anim) * Ref.RefSeq.AnimSeq.RateScale,
            0, Ref.RefSeq.AnimSeq.SequenceLength);
        Sampler = new(self) class'VRReloadRigSampler';
        Ready = Sampler.FindCarryGrip(Ref.Ref, Ref.RefSeq, Root, Track, Bridge.HandBone(StockHand),
            FMax(0, EndTime - 0.6 * Ref.RefSeq.AnimSeq.RateScale), EndTime, Time, P, Q, HandP, HandQ);
        if (!Ready && OtherTrack != '' && OtherTrack != Track)
        {
            Track = OtherTrack;
            Ready = Sampler.FindCarryGrip(Ref.Ref, Ref.RefSeq, Root, Track, Bridge.HandBone(StockHand),
                FMax(0, EndTime - 0.6 * Ref.RefSeq.AnimSeq.RateScale), EndTime, Time, P, Q, HandP, HandQ);
        }
    }
    Bridge.DetachComponent(Ref.Ref);
    return Ready;
}

static function bool Supports(KFWeapon W)
{
    local int Profile;
    local name Loaded;
    if (W == None || W.bDeleteMe || !W.bReloadFromMagazine || class'VRBreakAction'.static.Supported(W)) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(class'VRWeaponDropState'.static.FamilyFor(W.Class));
    if (Profile < 0 || class'VRReloadCatalog'.default.Profiles[Profile].bNoEject
        || class'VRReloadCatalog'.default.Profiles[Profile].bParkedLoaded
        || class'VRReloadCatalog'.default.Profiles[Profile].bPlateauInsert
        || class'VRReloadCatalog'.default.Profiles[Profile].bProjectilePlateau
        || class'VRReloadCatalog'.default.Profiles[Profile].bSeatAtNotify) return false;
    Loaded = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    return Loaded != 'RW_Cylinder' && Loaded != 'RW_GasTank1' && Loaded != 'RW_Container';
}

function bool Sample(VRHandsBridge Bridge, KFWeapon W, out name Anim,
    out name Track, out float Time, out int StockHand, optional byte AmmoSlot, optional byte PayloadKind)
{
    local int Profile, Hand;
    local name Clip, Root, Loaded, Spare;
    local float CarryAt;
    local bool bEmpty, bSampled;
    local KFSkeletalMeshComponent Ref;
    local AnimTree Template;
    local AnimNodeSequence Seq;
    local VRReloadRigSampler Sampler;
    local VRWeaponRuntime Runtime;
    local name Action;
    local float OpenStart, OpenEnd, LoadEnd, CloseStart, CloseEnd;
    Anim = ''; Track = ''; Time = 0; StockHand = 0;
    if (PayloadKind == 1)
    {
        // Single-shell rifles/pumps have a suitable original carrying clip.
        // Magazine-fed guns have no individual-loading choreography; their
        // normal free-hand closed grip carries the cartridge instead.
        if (class'VRPumpCatalog'.static.Covers(W) || class'VRCompoundBowAuthority'.static.Supports(W)
            || (class'VRBreakCatalog'.static.FindClass(W.Class) >= 0
                && class'VRBreakCatalog'.default.Profiles[class'VRBreakCatalog'.static.FindClass(W.Class)].ClipBone == ''))
        {
            if (SampleRecovery(Bridge, W, Anim, Track, Time, StockHand)) return true;
        }
        Anim = ''; Track = ''; Time = 0; StockHand = 0;
        return class'VRLiveRoundEjection'.static.RecoverySupported(class'VRWeaponDropState'.static.FamilyFor(W.Class));
    }
    if (AmmoSlot == 0 && RecoverableCylinder(W))
        return SampleCylinder(Bridge, W, Anim, Track, Time, StockHand);
    if (AmmoSlot == 0 && W != None && W.Class == class'KFWeap_Rifle_MosinNagant')
        return SampleStripper(Bridge, W, Anim, Track, Time, StockHand);
    if (AmmoSlot == 0 && RecoveryClass(W != None ? W.Class : None) && !Supports(W))
        return SampleRecovery(Bridge, W, Anim, Track, Time, StockHand);
    if (AmmoSlot == 1)
    {
        if (!class'VRSecondaryReloadCatalog'.static.Supported(W) || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None) return false;
        Anim = class'VRSecondaryReloadCatalog'.static.ReferenceClip(W);
        return class'VRSecondaryReloadCatalog'.static.GetProfile(W, Anim, Action, Track,
            OpenStart, OpenEnd, Time, LoadEnd, CloseStart, CloseEnd);
    }
    if (Bridge == None || Bridge.bDeleteMe || W == None || W.bDeleteMe
        || W.MySkelMesh == None || W.MySkelMesh.SkeletalMesh == None || !W.bReloadFromMagazine
        || class'VRBreakAction'.static.Supported(W)) return false;
    Profile = class'VRReloadCatalog'.static.FindClass(class'VRWeaponDropState'.static.FamilyFor(W.Class));
    if (Profile < 0 || W.MySkelMesh.SkeletalMesh.Name != class'VRReloadCatalog'.default.Profiles[Profile].MeshName
        || class'VRReloadCatalog'.default.Profiles[Profile].bNoEject
        || class'VRReloadCatalog'.default.Profiles[Profile].bParkedLoaded
        || class'VRReloadCatalog'.default.Profiles[Profile].bPlateauInsert
        || class'VRReloadCatalog'.default.Profiles[Profile].bProjectilePlateau
        || class'VRReloadCatalog'.default.Profiles[Profile].bSeatAtNotify) return false;
    Root = 'RW_Weapon';
    Loaded = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    Spare = class'VRReloadCatalog'.static.MagazineBone(Profile, true);
    // This first sampler handles detachable magazines, not whole cylinders,
    // tanks or blade containers that happen to use stock magazine accounting.
    if (Loaded == 'RW_Cylinder' || Loaded == 'RW_GasTank1' || Loaded == 'RW_Container') return false;
    if (Spare == class'VRReloadCatalog'.default.Profiles[Profile].KeepBone) Spare = Loaded;
    Hand = class'VRReloadCatalog'.default.Profiles[Profile].InsertHand;
    if (Hand < 0 || Hand > 1) return false;
    bEmpty = W.AmmoCount[0] <= 0;
    if (Bridge.HeldInventory != None) Runtime = Bridge.HeldInventory.FindItem(W);
    if (Runtime != None && ((Runtime.MagazineOut() && !Runtime.MagazineHasChamber())
        || (Runtime.EmptyMagazineFlags & 2) != 0)) bEmpty = true;
    Clip = bEmpty ? class'KFWeapon'.const.ReloadEmptyMagAnim : class'KFWeapon'.const.ReloadNonEmptyMagAnim;
    if (W.IsTimerActive('ReloadAmmoTimer') && W.WeaponAnimSeqNode != None
        && W.WeaponAnimSeqNode.AnimSeqName != '') Clip = W.WeaponAnimSeqNode.AnimSeqName;
    // Match VRInteractiveReload.RegularClip: physical magazine contact uses
    // the regular choreography even when stock's timer runs an elite clip.
    if (Clip == class'KFWeapon'.const.ReloadEmptyMagEliteAnim) Clip = class'KFWeapon'.const.ReloadEmptyMagAnim;
    if (Clip == class'KFWeapon'.const.ReloadNonEmptyMagEliteAnim) Clip = class'KFWeapon'.const.ReloadNonEmptyMagAnim;

    Template = new(Bridge) class'AnimTree';
    Seq = new(Template) class'AnimNodeSequence';
    Seq.NodeName = 'VRMagazineCarryReference';
    Seq.bNoNotifies = true; Seq.bPlaying = false;
    Template.Children[0].Anim = Seq; Template.Children[0].Weight = 1;
    Ref = new(Bridge) class'KFSkeletalMeshComponent';
    Ref.bUpdateSkelWhenNotRendered = true; Ref.bTickAnimNodesWhenNotRendered = false;
    Ref.CastShadow = false; Ref.bCastDynamicShadow = false;
    Ref.SetAbsolute(true, true, true);
    Ref.SetTranslation(vect(0,0,0)); Ref.SetRotation(rot(0,0,0)); Ref.SetScale(1);
    Ref.SetHidden(true);
    Ref.SetSkeletalMesh(W.MySkelMesh.SkeletalMesh);
    Ref.AnimSets = W.MySkelMesh.AnimSets;
    Ref.SetAnimTreeTemplate(Template);
    Bridge.AttachComponent(Ref);
    Seq = AnimNodeSequence(Ref.FindAnimNode('VRMagazineCarryReference'));
    if (Seq != None)
    {
        Sampler = new(self) class'VRReloadRigSampler';
        Sampler.ActionKind = class'VRReloadCatalog'.default.Profiles[Profile].ActionKind;
        // Removal preflight must use the same authored action limits and
        // wrist as insertion. Beluga's 18.5-UU handle exceeds the generic
        // 15-UU limit even though its catalog permits that real stroke.
        Sampler.RackSourceHand = Bridge.HandBone(class'VRReloadCatalog'.default.Profiles[Profile].RackHand);
        Sampler.bRackThumbContact = class'VRReloadCatalog'.default.Profiles[Profile].bRackThumbContact;
        Sampler.MaxRackStroke = class'VRReloadCatalog'.default.Profiles[Profile].MaxRackStroke;
        bSampled = Sampler.Sample(Ref, Seq, Clip, Root, Spare, Bridge.HandBone(Hand),
            class'VRReloadCatalog'.default.Profiles[Profile].RackBone,
            class'VRInteractiveReload'.default.EntryLead, Loaded,
            class'VRReloadCatalog'.default.Profiles[Profile].FollowBone);
        bSampled = bSampled && class'VRReloadCatalog'.static.UsableSample(Sampler, bEmpty);
        if (bSampled)
        {
            CarryAt = Sampler.EntryTime;
            if (class'VRReloadCatalog'.default.Profiles[Profile].bEarlierCarryGrip)
            {
                Sampler.SampleEarlierCarryGrip(Ref, Seq, Root, Bridge.HandBone(Hand));
                CarryAt = Sampler.CarryTime;
            }
            bSampled = Sampler.AmmoTrack != '' && Ref.MatchRefBone(Sampler.AmmoTrack) >= 0
                && class'VRReloadMotionGuard'.static.ValidTime(CarryAt);
        }
    }
    // Detach on every post-allocation path. No reference component, sequence
    // or sampler is retained; ordinary UObject collection owns their disposal.
    Ref.DetachFromAny();
    if (!bSampled) return false;
    Anim = Clip; Track = Sampler.AmmoTrack; Time = CarryAt; StockHand = Hand;
    return true;
}
