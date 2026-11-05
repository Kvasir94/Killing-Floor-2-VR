// Stock perks ask two single-weapon questions: which weapon is current
// (Pawn.Weapon, through KFPerk.GetOwnerWeapon) and whether it is aimed
// (KFWeapon.bUsingSights). VR holds an item in each hand and aims by grip,
// so native code brackets the stock calls that evaluate perks -- a shot
// (FireAmmunition), a hit on a Zed (its TakeDamage) and the authority's
// movement speed (UpdateGroundSpeed) -- with Begin/End. Inside a bracket
// Pawn.Weapon is the acting item and a braced shot counts as sighted; End
// restores both in LIFO order, so nested damage (explosions, shrapnel) and
// nested shots each see their own item. Temporary pawn/sight changes never
// persist between brackets; delayed projectiles retain bounded birth records.
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
    var bool bChangedSights, bSavedSights;
    var bool bFiring;
    var int Grip;
    var Weapon SavedWeapon;
    var KFWeapon Item;
};

struct ProjectileGrip
{
    var Projectile Shot;
    var KFWeapon Weapon;
    var int Grip;
};

const MaxProjectileGrips = 1024;
var array<ProjectileGrip> Projectiles;
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
    Projectiles.Length = 0;
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

// Latches immediate shot context. Delayed projectiles keep their own birth
// record below; a later shot must never rewrite an earlier projectile.
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

// Matching fire frames survive nested shots; the latest per-weapon slot does not.
function int FireFrame(KFWeapon W)
{
    local int I;
    for (I = Frames.Length - 1; I >= 0; --I)
        if (Frames[I].bFiring && Frames[I].Item == W) return I;
    return -1;
}

function RecordProjectile(Projectile P)
{
    local int I, F;
    local KFWeapon W;
    local ProjectileGrip Birth;
    if (P == None || P.bDeleteMe || Human == None || P.Instigator != Human) return;
    W = KFWeapon(P.Owner);
    if (W == None || W.bDeleteMe || W.Instigator != Human || W.InvManager != Human.InvManager) return;
    for (I = Projectiles.Length - 1; I >= 0; --I)
    {
        if (Projectiles[I].Shot == P) return;
        if (Projectiles[I].Shot == None || Projectiles[I].Shot.bDeleteMe
            || Projectiles[I].Weapon == None || Projectiles[I].Weapon.bDeleteMe) Projectiles.Remove(I, 1);
    }
    F = FireFrame(W);
    Birth.Shot = P; Birth.Weapon = W;
    Birth.Grip = F >= 0 ? Frames[F].Grip : LiveGrip(W);
    // Evicted history falls back to stock, never another projectile's shot.
    if (Projectiles.Length >= MaxProjectileGrips) Projectiles.Remove(0, 1);
    Projectiles.AddItem(Birth);
}

function int DamageGrip(Actor Causer)
{
    local int I;
    local KFWeapon W;
    W = ItemFromCauser(Causer);
    if (Projectile(Causer) == None) return ShotGrip(W);
    for (I = Projectiles.Length - 1; I >= 0; --I)
    {
        if (Projectiles[I].Shot == Causer)
            return Projectiles[I].Weapon == W ? Projectiles[I].Grip : -1;
        if (Projectiles[I].Shot == None || Projectiles[I].Shot.bDeleteMe
            || Projectiles[I].Weapon == None || Projectiles[I].Weapon.bDeleteMe) Projectiles.Remove(I, 1);
    }
    // Init records before it can damage. Missing/evicted history is stock,
    // even if another shot from this weapon happens to be on the call stack.
    return -1;
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
function Begin(KFWeapon Item, int Grip, optional bool bFiring)
{
    local PerkFrame F;
    local int I;
    local bool StockSights, WantedSights;
    ++NativeBegins;
    if (Human != None && !Human.bDeleteMe && Item != None && !Item.bDeleteMe
        && Item.Instigator == Human && Item.InvManager == Human.InvManager)
    {
        F.bSwapped = true;
        F.SavedWeapon = Human.Weapon;
        F.Item = Item; F.Grip = Grip; F.bFiring = bFiring;
        Human.Weapon = Item;
        F.bSavedSights = Item.bUsingSights;
        StockSights = F.bSavedSights;
        // An older hip projectile can land inside a newer braced shot.
        // Recover genuine stock aim from the outermost matching frame so
        // synthetic VR sights do not leak into that projectile's context.
        for (I = 0; I < Frames.Length; ++I)
            if (Frames[I].bSwapped && Frames[I].Item == Item)
            { StockSights = Frames[I].bSavedSights; break; }
        WantedSights = StockSights || Grip == 1;
        F.bChangedSights = WantedSights != F.bSavedSights;
        if (F.bChangedSights) Item.bUsingSights = WantedSights;
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
    if (F.bChangedSights && F.Item != None) F.Item.bUsingSights = F.bSavedSights;
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
