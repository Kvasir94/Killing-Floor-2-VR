// One exact removal receipt, retained independently of the reload session so
// cancellation cannot abandon an accepted debit or mint a second magazine.
class VRMagazineRemoval extends Object;

var VRInteractiveReload Owner;
var VRWeaponRuntime Runtime;
var KFWeapon Gun;
var int Request;
var byte Status; // 0 unused, 1 waiting, 2 accepted, 3 refused/abandoned
var StaticMesh Mesh;
var MaterialInterface Surface0, Surface1, Surface2;
var vector Position, Velocity, Centre, Extent, ExitAxis;
var quat Rotation;
var name Root, CarryAnim, CarryTrack;
var float Scale, CarryTime;
var int StockHand;
var int ExitHand;
var vector WorldExitAxis;
var float ExitClearance;
var bool bEmptySound, bTacticalReady, bCylinderRemoval;

function bool Begin(VRInteractiveReload R, VRWeaponRuntime Item, MeshComponent Prop,
    name MagazineBone, name RootBone, vector PropCentre, vector PropExtent,
    vector ReleaseVelocity, vector WellAxis, int Kept, optional int PairSession)
{
    local VRMagazineCarryRecipe Recipe;
    local int Serial;
    local vector LocalAxis;
    if (Status == 1 || R == None || Item == None || Item.Item == None
        || Item.MagazineOut() || !class'VRMagazineCarryRecipe'.static.Supports(Item.Item) || Prop == None
        || StaticMeshComponent(Prop) == None || Item.Item.MySkelMesh == None) return false;
    Owner = R; Runtime = Item; Gun = Item.Item; bCylinderRemoval = false;
    Item.MagazineFeedEvent(0);
    bEmptySound = Item.TracksMagazineFeed() ? !Item.MagazineHasChamber() : Gun.AmmoCount[0] <= 0;
    bTacticalReady = Item.SupportsTacticalMagazineRemoval()
        && Gun.AmmoCount[0] > 0 && !Item.MagazineNeedsRack();
    Recipe = new(self) class'VRMagazineCarryRecipe';
    if (!Recipe.Sample(R.Bridge, Gun, CarryAnim, CarryTrack, CarryTime, StockHand)) return false;
    Mesh = StaticMeshComponent(Prop).StaticMesh;
    Surface0 = Prop.GetMaterial(0); Surface1 = Prop.GetMaterial(1); Surface2 = Prop.GetMaterial(2);
    Position = Gun.MySkelMesh.GetBoneLocation(MagazineBone);
    Rotation = Gun.MySkelMesh.GetBoneQuaternion(MagazineBone);
    Scale = R.ScaleOf(Gun); Centre = PropCentre; Extent = PropExtent;
    Velocity = ReleaseVelocity; ExitAxis = WellAxis; Root = RootBone;
    ExitHand = Item.PrimaryHand >= 0 ? Item.PrimaryHand : Item.SupportHand;
    WorldExitAxis = vect(0,0,0); ExitClearance = 0;
    if (VSize(ExitAxis) > 0.5)
    {
        WorldExitAxis = QuatRotateVector(Gun.MySkelMesh.GetBoneQuaternion(Root), Normal(ExitAxis));
        LocalAxis = QuatRotateVector(QuatInvert(Rotation), WorldExitAxis);
        ExitClearance = 2 * Scale * (Abs(LocalAxis.X) * Extent.X
            + Abs(LocalAxis.Y) * Extent.Y + Abs(LocalAxis.Z) * Extent.Z);
    }
    // End the old stock transaction before the weapon-channel marker. Its
    // unseated replacement paid nothing; no later EndState may sync that count.
    if (PairSession <= 0 && R.MagazineReloading(Gun))
    {
        Gun.ClearTimer('ReloadAmmoTimer'); Gun.ClearTimer('ReloadStatusTimer');
        Gun.InitialReloadAmount = Gun.ReloadAmountLeft;
        Gun.AbortReload();
    }
    Serial = R.Bridge.BeginMagazineRemoval(Gun, Kept, R.LosesReloadAmmo(), PairSession);
    if (Serial <= 0) { Status = 3; return false; }
    Request = Serial; Status = 1;
    return true;
}

// A network single's whole1858 cylinder uses the same ordered stock count
// barrier and paid removal receipt, without admitting a detachable well.
function bool BeginCylinder(VRInteractiveReload R, VRWeaponRuntime Item)
{
    local int Serial;
    local VRMagazineCarryRecipe Recipe;
    local name DropBone;
    local int Profile;
    if (Status == 1 || R == None || Item == None || Item.Item == None
        || (!class'VRMagazineCarryRecipe'.static.WholeLoad(Item.Item) && !class'VRBreakCatalog'.static.SwingOutCylinder(Item.Item))
        || Item.Item.AmmoCount[0] <= 0 || Item.Item.MySkelMesh == None) return false;
    Owner = R; Runtime = Item; Gun = Item.Item; bCylinderRemoval = true;
    Recipe = new(self) class'VRMagazineCarryRecipe';
    if (!class'VRBreakCatalog'.static.SwingOutCylinder(Gun)
        && !Recipe.Sample(R.Bridge, Gun, CarryAnim, CarryTrack, CarryTime, StockHand)) return false;
    DropBone = 'RW_Cylinder';
    Profile = class'VRReloadCatalog'.static.FindClass(Gun.Class);
    if (Profile >= 0) DropBone = class'VRReloadCatalog'.static.MagazineBone(Profile, false);
    else
    {
        Profile = class'VRBreakCatalog'.static.FindClass(Gun.Class);
        if (Profile >= 0 && class'VRBreakCatalog'.default.Profiles[Profile].DropBone != '')
            DropBone = class'VRBreakCatalog'.default.Profiles[Profile].DropBone;
    }
    if (Gun.MySkelMesh.MatchRefBone(DropBone) < 0) return false;
    Position = Gun.MySkelMesh.GetBoneLocation(DropBone);
    Rotation = Gun.MySkelMesh.GetBoneQuaternion(DropBone);
    Scale = R.ScaleOf(Gun); Velocity = R.GunDropVelocity(vect(0,0,-60));
    WorldExitAxis = vect(0,0,0); ExitClearance = 0;
    ExitHand = Item.PrimaryHand >= 0 ? Item.PrimaryHand : Item.SupportHand;
    bEmptySound = false; bTacticalReady = false;
    // Keep this cylinder's original reload choreography. The server holds
    // its timers, resizes its stock payment and corrects ammo before the receipt.
    Serial = R.Bridge.BeginMagazineRemoval(Gun, 0, true);
    if (Serial <= 0) { Status = 3; return false; }
    Request = Serial; Status = 1;
    // Resize only the initiating reload's unpaid baseline. A later accepted
    // receipt may survive cancellation, and must not rewrite a newer reload.
    Gun.ReloadAmountLeft = Max(Min(Gun.MagazineCapacity[0], Gun.SpareAmmoCount[0]), 0);
    Gun.InitialReloadAmount = Gun.ReloadAmountLeft;
    return true;
}

function Poll()
{
    local byte Result, Kind, Accepted, Retired;
    local int Actual, Remaining;
    local KFWeapon W;
    if (Status != 1) return;
    Result = Owner.Bridge.ReadMagazineAction(Request, Kind, Accepted, W, Actual, Remaining, Retired);
    if (Result == 0) return;
    Status = 3;
    if (Result != 1 || Kind != 0 || Accepted == 0 || W != Gun || Actual < 0 || Actual != Remaining) return;
    Status = 2;
    // Sound the removal only once its exact receipt admits the physical drop.
    // This owner survives cancellation and is shared by both loading routes.
    if (Owner.Audio != None)
    {
        Owner.Audio.PlayMappedCue(Gun, 6, bEmptySound, Position);
        Owner.Audio.PlayMappedCue(Gun, 1, bEmptySound, Position);
    }
    if (Runtime != None && Runtime.IsCurrent() && Runtime.Item == Gun)
    {
        if (Runtime.PrimaryHand >= 0)
            class'VRMechanismHaptics'.static.Emit(Owner.Bridge, class'VRMechanismHaptics'.const.Contact, 1 << Runtime.PrimaryHand);
        Runtime.StockChamberBonus = 0;
        if (bCylinderRemoval)
        {
            // The receipt owns this emptied load even if the initiating
            // physical reload was stowed or cancelled while it was in flight.
            Owner.MarkLoadEmptied(Runtime, true);
        }
        else
        {
            if (Runtime.SupportsTacticalMagazineRemoval()) Runtime.bTacticalMagazineRemoval = bTacticalReady;
            Runtime.MagazineFeedEvent(1);
            Runtime.EmptyMagazineEvent(0);
        }
    }
    // The registry already published the exact paid payload when removal was
    // accepted. Improve that existing actor's pose, never mint a second local
    // prop or depend on a ten-slot cosmetic pool to preserve ammunition.
    Owner.Bridge.PublishMagazinePresentation(Request, Position, QuatToRotator(Rotation), Velocity, Scale,
        None, WorldExitAxis, ExitClearance, ExitHand);
}
