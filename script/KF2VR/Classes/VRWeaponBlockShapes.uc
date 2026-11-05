// Contact solids in the authored first-person root frame. Empty/unsupported
// parts never fall back to inventory bounds, hands, magazines or a reach sphere.
class VRWeaponBlockShapes extends Object dependsOn(VRWeaponBlockGeometry, VRHandsBridge);

static function int Profile(KFWeapon W)
{
    return W!=None ? ProfileClass(W.Class) : -1;
}

static function int ProfileClass(class<KFWeapon> WeaponClass)
{
    local int I,J;
    local name N;
    if(WeaponClass==None) return -1;
    N=WeaponClass.Name;
    for(J=0;J<class'VRHandsBridge'.default.AuditedSubclasses.Length;++J)
        if(class'VRHandsBridge'.default.AuditedSubclasses[J].SubclassName==N)
        { N=class'VRHandsBridge'.default.AuditedSubclasses[J].ProfileClassName; break; }
    for(I=0;I<class'VRHandsBridge'.default.WeaponProfiles.Length;++I)
        if(class'VRHandsBridge'.default.WeaponProfiles[I].WeaponClassName==N) return I;
    return -1;
}

static function bool PublishesRoot(int P)
{
    return P>=0 && P<class'VRHandsBridge'.default.WeaponProfiles.Length
        && class'VRHandsBridge'.default.WeaponProfiles[P].bPhysicalMelee
        && !class'VRHandsBridge'.default.WeaponProfiles[P].bFirearm;
}

static function Add(out array<BlockCapsule> Shapes, vector A, vector B, float Radius)
{
    local BlockCapsule S;
    S.A=A; S.B=B; S.Radius=Radius; Shapes.AddItem(S);
}

static function bool Get(KFWeapon W, out array<BlockCapsule> Shapes)
{
    local int P;
    local VRHandsBridge.VRWeaponProfile Data;
    Shapes.Length=0;
    if(W==None) return false;
    if(W.Class==class'KFWeap_Edged_Katana')
    {
        Add(Shapes,vect(0,0.45,12),vect(0,3.7,38),2.1);
        Add(Shapes,vect(0,3.7,38),vect(0,8.2,63),2.1);
        Add(Shapes,vect(0,8.2,63),vect(0,14.1,87.8),1.6);
    }
    else if(class'VRWeaponBlockFirearms'.static.Get(W,Shapes)) return true;
    else
    {
        P=Profile(W);
        if(P<0) return false;
        Data=class'VRHandsBridge'.default.WeaponProfiles[P];
        if(Data.bPhysicalMelee && !Data.bPhysicalDualGauntlets && Data.MeleeRadius>0)
            Add(Shapes,Data.MeleeHeadStart,Data.MeleeHeadEnd,Data.MeleeRadius);
    }
    return Shapes.Length>0;
}
