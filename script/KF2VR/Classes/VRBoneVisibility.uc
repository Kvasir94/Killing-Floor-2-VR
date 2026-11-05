// Native hide/unhide indexes evaluated pose arrays, not just the skeleton.
// Equip can expose a valid bone name before those arrays have been created.
class VRBoneVisibility extends Object;

// IsBoneHidden indexes BoneVisibilityStates, which a mesh just attached or
// re-attached (a caught or recalled gun) has not built yet. Past its end the
// engine asserts and the game exits. Unbuilt states read as visible.
static function bool IsHidden(SkeletalMeshComponent Mesh, name Bone)
{
    local int Index;
    if (Mesh == None || Mesh.SkeletalMesh == None) return false;
    Index = Mesh.MatchRefBone(Bone);
    return IsHiddenIndex(Mesh, Index);
}

static function bool IsHiddenIndex(SkeletalMeshComponent Mesh, int Index)
{
    return Mesh != None && Index >= 0 && Index < Mesh.BoneVisibilityStates.Length && Mesh.IsBoneHidden(Index);
}

// Every script hide or unhide goes through here. Native HideBone indexes
// LocalAtoms and BoneVisibilityStates without a check, and a gun just caught,
// recalled or swapped may not have built them yet: the engine asserts and the
// game exits. A bone whose arrays are not built yet is left as it is.
static function bool SetVisible(SkeletalMeshComponent Mesh, name Bone, bool bVisible)
{
    local int Index;
    if (Mesh == None || Mesh.SkeletalMesh == None) return false;
    Index = Mesh.MatchRefBone(Bone);
    if (Index < 0 || Index >= Mesh.LocalAtoms.Length
        || Index >= Mesh.SpaceBases.Length || Index >= Mesh.BoneVisibilityStates.Length) return false;
    if (Mesh.IsBoneHidden(Index) == !bVisible) return false;
    if (bVisible) Mesh.UnHideBoneByName(Bone);
    else Mesh.HideBoneByName(Bone, PBO_None);
    return true;
}
