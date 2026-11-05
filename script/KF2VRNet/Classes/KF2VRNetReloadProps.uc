// Observer-only carried ammunition. Never owns inventory, physics or payment.
class KF2VRNetReloadProps extends Object dependsOn(KF2VRNetTypes);

var StaticMeshComponent Components[5];
var NetReloadProp Bound[5];
var byte Attempted[5];

function MaterialInterface Surface(SkeletalMesh Rig, array<string> Skins, int Slot)
{
    local MaterialInterface Result;
    if (Slot < 0 || Slot >= Rig.Materials.Length) return None;
    if (Slot < Skins.Length && Skins[Slot] != "")
        Result = MaterialInterface(DynamicLoadObject(Skins[Slot], class'MaterialInterface', true));
    return Result != None ? Result : Rig.Materials[Slot];
}

function bool Bind(KF2VRNetPose Owner, int Index, NetReloadProp Prop)
{
    local SkeletalMesh Rig, RoundRig;
    local StaticMesh Asset;
    local MaterialInterface M0, M1, M2;
    local array<string> Skins;
    local int Profile, BreakProfile, PumpProfile, Slot;
    if (Components[Index] != None) Owner.DetachComponent(Components[Index]);
    Components[Index] = None;
    Attempted[Index] = 1;
    Bound[Index] = Prop;
    if (Prop.Family == None) return false;
    Rig = SkeletalMesh(DynamicLoadObject(Prop.Family.default.FirstPersonMeshName, class'SkeletalMesh', true));
    if (Rig == None) return false;
    Asset = StaticMesh(DynamicLoadObject((Prop.AmmoSlot == 1 ? "KF2VRHands.VRAmmo_Alt_" : "KF2VRHands.VRAmmo_")
        $ Rig.Name, class'StaticMesh', true));
    if (Asset == None) return false;
    if (Prop.SkinId > 0) Skins = class'KFWeaponSkinList'.static.GetWeaponSkinPaths(Prop.SkinId, WST_FirstPerson);
    Profile = class'VRReloadCatalog'.static.FindClass(Prop.Family);
    BreakProfile = class'VRBreakCatalog'.static.FindClass(Prop.Family);
    if (Prop.AmmoSlot == 1)
    {
        Slot = (Prop.Family == class'KFWeap_AssaultRifle_M16M203'
            || Prop.Family == class'KFWeap_AssaultRifle_HRGIncendiaryRifle') ? 1 : 0;
        M0 = Surface(Rig, Skins, Slot);
    }
    else
    {
        Slot = Profile >= 0 ? class'VRReloadCatalog'.default.Profiles[Profile].MaterialIndex
            : (BreakProfile >= 0 ? class'VRBreakCatalog'.default.Profiles[BreakProfile].MaterialIndex : 0);
        M0 = Surface(Rig, Skins, Slot);
        if (Profile >= 0)
        {
            M1 = Surface(Rig, Skins, class'VRReloadCatalog'.default.Profiles[Profile].Section1MaterialIndex);
            Slot = class'VRReloadCatalog'.default.Profiles[Profile].Section2MaterialIndex;
            if (Slot > 0) M2 = Surface(Rig, Skins, Slot);
        }
        else if (BreakProfile >= 0)
        {
            M1 = Surface(Rig, Skins, class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialIndex);
            if (class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialMesh != "")
            {
                RoundRig = SkeletalMesh(DynamicLoadObject(class'VRBreakCatalog'.default.Profiles[BreakProfile].Section1MaterialMesh, class'SkeletalMesh', true));
                if (RoundRig != None && RoundRig.Materials.Length > 0) M1 = RoundRig.Materials[0];
            }
        }
        PumpProfile = class'VRPumpCatalog'.static.FindClass(Prop.Family);
        if (PumpProfile >= 0 && class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh != "")
        {
            RoundRig = SkeletalMesh(DynamicLoadObject(class'VRPumpCatalog'.default.Profiles[PumpProfile].AmmoMaterialMesh, class'SkeletalMesh', true));
            if (RoundRig != None && RoundRig.Materials.Length > 0) M0 = RoundRig.Materials[0];
        }
    }
    Components[Index] = new(Owner) class'StaticMeshComponent';
    Components[Index].SetStaticMesh(Asset);
    if (M0 != None) Components[Index].SetMaterial(0, M0);
    if (M1 != None) Components[Index].SetMaterial(1, M1);
    if (M2 != None) Components[Index].SetMaterial(2, M2);
    Components[Index].SetActorCollision(false, false);
    Components[Index].SetTraceBlocking(false, false);
    Components[Index].SetAbsolute(true, true, true);
    Components[Index].CastShadow = false;
    Components[Index].SetHidden(true);
    Owner.AttachComponent(Components[Index]);
    return true;
}

function Hide()
{
    local int I;
    for (I = 0; I < 5; ++I) if (Components[I] != None) Components[I].SetHidden(true);
}

function Shutdown(KF2VRNetPose Owner)
{
    local int I;
    for (I = 0; I < 5; ++I)
    {
        if (Components[I] != None) Owner.DetachComponent(Components[I]);
        Components[I] = None;
    }
}

function Update(KF2VRNetPose Owner, NetPoseSnapshot Frame, NetPoseSnapshot Latest,
    bool bFresh, vector Root, rotator Basis, KF2VRNetRemoteBody Body)
{
    local int I, J, Slot;
    local NetReloadProp Prop;
    local vector Correction;
    Hide();
    if (!bFresh || Body == None || !Body.IsReady() || Frame.Motion.bEnabled) return;
    for (I = 0; I < Frame.Sample.ReloadProps.Length && I < 5; ++I)
    {
        Prop = Frame.Sample.ReloadProps[I];
        // Clear immediately on loss/seat/stow; interpolation must not resurrect
        // a retired prop while old snapshots remain in the presentation buffer.
        for (J = 0; J < Latest.Sample.ReloadProps.Length; ++J)
            if (class'KF2VRNetTypes'.static.SameReloadProp(Prop, Latest.Sample.ReloadProps[J])) break;
        Slot = Prop.PropSlot;
        if (Slot >= 5 || J >= Latest.Sample.ReloadProps.Length
            || (Latest.Sample.TrackingFlags & (2 << Prop.Hand)) == 0) continue;
        // A new pickup needs a new motion identity, not a new mesh allocation.
        if (Prop.Family != Bound[Slot].Family || Prop.SkinId != Bound[Slot].SkinId
            || Prop.AmmoSlot != Bound[Slot].AmmoSlot || Attempted[Slot] == 0)
            if (!Bind(Owner, Slot, Prop)) continue;
        if (Components[Slot] == None) continue;
        Correction = Body.HandCorrection + Body.ReachShift[Prop.Hand];
        Components[Slot].SetTranslation(Root + (Prop.Position >> Basis) + Correction);
        Components[Slot].SetRotation(Normalize(Basis + Prop.Rotation));
        Components[Slot].SetScale3D(Prop.Scale);
        Components[Slot].SetHidden(false);
        Components[Slot].ForceUpdate(true);
    }
}
