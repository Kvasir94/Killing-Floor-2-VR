// Stock perks ask two single-weapon questions: which weapon is current
// (Pawn.Weapon, through KFPerk.GetOwnerWeapon) and whether it is aimed
// (KFWeapon.bUsingSights). VR holds an item in each hand and aims by grip,
// so native code brackets the stock calls that evaluate perks -- a shot
// (FireAmmunition), a hit on a Zed (its TakeDamage) and the authority's
// movement speed (UpdateGroundSpeed) -- with Begin/End. Inside a bracket
// Pawn.Weapon is the acting item and a braced shot counts as sighted; End
// restores both in LIFO order, so nested damage (explosions, shrapnel) and
// nested shots each see their own item. Nothing persists between brackets.
//
// Owned per player by the authority's hand model: VRHandsBridge in solo,
// KF2VRNetHeldInventory on a dedicated server. The grip of each held item
// is 1 braced/one-handed pistol (sighted), 0 hip, -1 unmanaged (stock).
class VRPerkContext extends Object;

struct ItemGrip
{
    var KFWeapon Weapon;
    var int Live;      // grip reported now
    var int Shot;      // grip when this item last fired; -1 before a shot
};

struct PerkFrame
{
    var bool bSwapped;
    var bool bRaisedSights;
    var Weapon SavedWeapon;
    var KFWeapon Item;
};

var KFPawn_Human Human;
var array<ItemGrip> Grips;
var array<PerkFrame> Frames;
var bool bChoosingMovement;
var int NativeBegins, NativeEnds;

function Bind(KFPawn_Human P)
{
    if (P == Human) return;
    // A new body: nothing from the previous one may be restored onto it.
    Human = P;
    Grips.Length = 0;
    Frames.Length = 0;
}

function int Find(KFWeapon W)
{
    local int I;
    for (I = Grips.Length - 1; I >= 0; --I)
    {
        if (Grips[I].Weapon == None || Grips[I].Weapon.bDeleteMe) { Grips.Remove(I, 1); continue; }
        if (Grips[I].Weapon == W) return I;
    }
    return -1;
}

function SetGrip(KFWeapon W, int Policy)
{
    local int I;
    if (W == None || W.bDeleteMe || W.Instigator != Human) return;
    I = Find(W);
    if (I < 0)
    {
        I = Grips.Length;
        Grips.Length = I + 1;
        Grips[I].Weapon = W;
        Grips[I].Shot = -1;
    }
    Grips[I].Live = Clamp(Policy, -1, 1);
}

// Latches the live grip as this item's shot grip. Projectiles land after the
// hands may have moved; their hit is judged by the grip that fired them.
function RecordShot(KFWeapon W)
{
    local int I;
    I = Find(W);
    if (I >= 0) Grips[I].Shot = Grips[I].Live;
}

function int LiveGrip(KFWeapon W)
{
    local int I;
    I = Find(W);
    return I < 0 ? -1 : Grips[I].Live;
}

function int ShotGrip(KFWeapon W)
{
    local int I;
    I = Find(W);
    if (I < 0) return -1;
    return Grips[I].Shot >= 0 ? Grips[I].Shot : Grips[I].Live;
}

// The stock perk resolution of a damage causer (KFPerk.GetWeaponFromDamageCauser).
static function KFWeapon ItemFromCauser(Actor Causer)
{
    if (Causer == None) return None;
    if (KFWeapon(Causer) != None) return KFWeapon(Causer);
    if (Projectile(Causer) != None) return KFWeapon(Causer.Owner);
    if (KFSprayActor(Causer) != None) return KFWeapon(Causer.Base);
    return None;
}

// Always pushes a frame, so every End has a partner even when nothing applies.
function Begin(KFWeapon Item, int Grip)
{
    local PerkFrame F;
    ++NativeBegins;
    if (Human != None && !Human.bDeleteMe && Item != None && !Item.bDeleteMe
        && Item.Instigator == Human && Item.InvManager == Human.InvManager)
    {
        F.bSwapped = true;
        F.SavedWeapon = Human.Weapon;
        F.Item = Item;
        Human.Weapon = Item;
        // Only ever raised: a Seeker/Rail Gun lock or a raised Riot Shield
        // already holds the flag and must keep it.
        if (Grip == 1 && !Item.bUsingSights)
        {
            Item.bUsingSights = true;
            F.bRaisedSights = true;
        }
    }
    Frames.AddItem(F);
}

function End()
{
    local PerkFrame F;
    ++NativeEnds;
    if (Frames.Length == 0) return;
    F = Frames[Frames.Length - 1];
    Frames.Remove(Frames.Length - 1, 1);
    if (!F.bSwapped) return;
    if (F.bRaisedSights && F.Item != None) F.Item.bUsingSights = false;
    // A stock switch completed inside the bracket keeps its own result.
    if (Human != None && Human.Weapon == F.Item) Human.Weapon = F.SavedWeapon;
}

// Movement skills belong to whichever hand qualifies: Ninja, Tactical
// Movement, Melee Expert, Crouch Aim and Trigger read the current weapon.
// Stock speed only ever gains from them, so evaluate each held item and keep
// the faster. Returns the item to evaluate under, or None for stock.
function KFWeapon ChooseMovementItem(KFWeapon Left, KFWeapon Right)
{
    local float SpeedLeft, SprintLeft;
    if (Human == None || bChoosingMovement) return None;
    if (Left == None || Left == Right) return Right;
    if (Right == None) return Left;
    bChoosingMovement = true;
    Begin(Left, -1);
    Human.UpdateGroundSpeed();
    End();
    SpeedLeft = Human.GroundSpeed;
    SprintLeft = Human.SprintSpeed;
    Begin(Right, -1);
    Human.UpdateGroundSpeed();
    End();
    bChoosingMovement = false;
    return (SpeedLeft > Human.GroundSpeed || (SpeedLeft == Human.GroundSpeed && SprintLeft > Human.SprintSpeed))
        ? Left : Right;
}
