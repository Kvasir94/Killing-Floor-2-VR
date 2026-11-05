// Opt-in testing mode. Only a launch URL carrying both this mutator and
// ?KF2VRTestMode=1 enables it; nothing is config-backed, so ordinary launches
// cannot inherit it. Server authority only: works the same in Solo, on a
// listen host and on the dedicated server. Clients change perk through the
// stock perk menu at any time (the server applies the pending change at once
// instead of at wave end), or with "mutate kf2vrtest perk <name>". Every perk
// switch strips the inventory and grants every weapon of the new perk.
class VRTestMode extends KFMutator;

struct TestPlayer
{
    var KFPlayerController PC;
    var KFPawn_Human Pawn;
    var class<KFPerk> Perk;
    var array<class<KFWeapon> > Queue;
    var int Next, Granted;
    var bool bJob, bStrip;
    var class<KFPerk> LastApplyClass;
    var float LastApplyAt;
};

var bool bEnabled, bCatalogReady;
var VRLocalTestRegistry Registry;
// Every weapon the trader sells, resolved from its weapon definitions, so the
// grant covers stock and DLC guns that have no authored VR profile yet.
var array<class<KFWeapon> > TraderWeapons;
var int TraderScan;
var array<TestPlayer> Players;

function InitMutator(string Options, out string ErrorMessage)
{
    Super.InitMutator(Options, ErrorMessage);
    if (MyKFGI == None || Role != ROLE_Authority || MyKFGI.ParseOption(Options, "KF2VRTestMode") != "1") return;
    bEnabled = true;
    Registry = new(self) class'VRLocalTestRegistry';
    Registry.Build(InStr("," $ Caps(MyKFGI.ParseOption(Options, "Mutator")) $ ",",
        ",KF2BREACHER.BREACHERMUTATOR,") >= 0);
    // Free perk switching and full arsenals are not a ranked game.
    MyKFGI.SetGameUnranked(true);
    MyKFGI.UpdateGameSettings();
    SetTimer(0.1, true, 'AdvanceTestMode');
    `log("KF2VR_TEST_MODE enabled=1 netmode=" $ WorldInfo.NetMode @ "map=" $ WorldInfo.GetMapName(true)
        @ "registry=" $ Registry.Weapons.Length @ "unranked=1");
}

// Load trader weapon classes a few per tick so the map start does not hitch.
function ScanTraderCatalog()
{
    local KFGFxObject_TraderItems Items;
    local class<KFWeapon> W;
    local int Count;
    if (bCatalogReady) return;
    Items = MyKFGI.MyKFGRI != None ? MyKFGI.MyKFGRI.TraderItems : None;
    if (Items == None) return;
    while (TraderScan < Items.SaleItems.Length && Count++ < 12)
    {
        if (Items.SaleItems[TraderScan].WeaponDef != None
            && Items.SaleItems[TraderScan].WeaponDef.default.WeaponClassPath != "")
        {
            W = class<KFWeapon>(DynamicLoadObject(Items.SaleItems[TraderScan].WeaponDef.default.WeaponClassPath, class'Class', true));
            if (W != None && TraderWeapons.Find(W) == INDEX_NONE) TraderWeapons.AddItem(W);
        }
        ++TraderScan;
    }
    if (TraderScan >= Items.SaleItems.Length)
    {
        bCatalogReady = true;
        `log("KF2VR_TEST_MODE catalog trader=" $ TraderWeapons.Length @ "registry=" $ Registry.Weapons.Length);
    }
}

function bool BelongsToPerk(class<KFWeapon> W, class<KFPerk> Perk)
{
    local array<class<KFPerk> > Associations;
    Associations = W.static.GetAssociatedPerkClasses();
    return Associations.Find(Perk) != INDEX_NONE;
}

function bool Owned(KFInventoryManager IM, class<KFWeapon> W)
{
    local Inventory Item;
    local VRWeaponPair Pair;
    local int Count;
    if (Registry.AlreadyOwned(IM, W)) return true;
    for (Item = IM.InventoryChain; Item != None && Count < 256; Item = Item.Inventory)
    {
        ++Count;
        if (ClassIsChildOf(Item.Class, W)) return true;
        // A converted VR pair keeps its stock dual outside the chain.
        Pair = KFWeapon(Item) != None ? class'VRWeaponPair'.static.ForMember(KFWeapon(Item)) : None;
        if (Pair != None && Pair.StockItem != None && ClassIsChildOf(Pair.StockItem.Class, W)) return true;
    }
    return false;
}

function int ActualWeight(KFInventoryManager IM)
{
    local Inventory Item;
    local KFWeapon W;
    local int Total, Count;
    for (Item = IM.InventoryChain; Item != None && Count < 256; Item = Item.Inventory)
    {
        ++Count;
        W = KFWeapon(Item);
        // Instance weight: VR pair members override it.
        if (W != None) Total += Max(0, W.GetModifiedWeightValue());
    }
    return Total;
}

function int PlayerIndex(KFPlayerController PC)
{
    local TestPlayer Entry;
    local int I;
    I = Players.Find('PC', PC);
    if (I != INDEX_NONE) return I;
    Entry.PC = PC;
    Players.AddItem(Entry);
    return Players.Length - 1;
}

function KFPawn_Human LivingPawn(KFPlayerController PC)
{
    local KFPawn_Human Human;
    Human = KFPawn_Human(PC.Pawn);
    if (Human == None || Human.bDeleteMe || Human.Health <= 0 || KFPawn_Customization(Human) != None
        || KFInventoryManager(Human.InvManager) == None) return None;
    return Human;
}

// The stock perk menu leaves a mid-wave choice pending until the next wave.
// Test mode applies it now, through the same call the wave transition uses.
function ApplyPendingPerk(int I)
{
    local KFPlayerController PC;
    PC = Players[I].PC;
    if (PC.ServPendingPerkClass == None || PC.GetPerk() == None) return;
    // Once applied, clear the request so a stale one can never undo a later
    // trader switch, and choosing the same perk again is a fresh change.
    if (PC.ServPendingPerkClass == PC.GetPerk().Class) { PC.ServPendingPerkClass = None; return; }
    if (Players[I].LastApplyClass == PC.ServPendingPerkClass && WorldInfo.RealTimeSeconds - Players[I].LastApplyAt < 2) return;
    Players[I].LastApplyClass = PC.ServPendingPerkClass;
    Players[I].LastApplyAt = WorldInfo.RealTimeSeconds;
    `log("KF2VR_TEST_MODE apply_pending player=" $ PC.PlayerReplicationInfo.PlayerID
        @ "from=" $ PC.GetPerk().Class @ "to=" $ PC.ServPendingPerkClass);
    PC.ApplyPendingPerks();
}

function bool SelectPerk(KFPlayerController PC, string Wanted)
{
    local int I;
    local class<KFPerk> Perk;
    for (I = 0; I < PC.PerkList.Length; ++I)
    {
        Perk = PC.PerkList[I].PerkClass;
        if (Perk == None) continue;
        if (Wanted ~= string(Perk.Name) || ("KFPerk_" $ Wanted) ~= string(Perk.Name)
            || Wanted ~= Perk.default.PerkName || Wanted == string(I)) break;
    }
    if (I >= PC.PerkList.Length) return false;
    // Same server-side route as the VR range's perk buttons.
    PC.ServPendingPerkClass = Perk;
    PC.ServPendingPerkLevel = PC.PerkList[I].PerkLevel;
    PC.ServPendingPerkPrestigeLevel = PC.PerkList[I].PrestigeLevel;
    PC.ServPendingPerkBuild = PC.GetPerkBuildByPerkClass(Perk);
    PC.ApplyPendingPerks();
    return true;
}

function StartJob(int I, bool bStrip)
{
    Players[I].bJob = true;
    Players[I].bStrip = bStrip;
    Players[I].Queue.Length = 0;
    Players[I].Next = 0;
    Players[I].Granted = 0;
}

// Remove every weapon except the healer and welder, then give the new perk's
// stock spawn loadout (knife, sidearm, starter, grenades) before the full list.
function StripToPerkDefaults(KFPawn_Human Human)
{
    local KFInventoryManager IM;
    local KFWeapon W;
    local VRWeaponPair Pair;
    local array<VRWeaponPair> Pairs;
    local array<KFWeapon> Remove;
    local int I;
    IM = KFInventoryManager(Human.InvManager);
    // Return VR pairs to their stock dual first; destroying the members alone
    // would orphan the pair and its hidden stock actor.
    foreach IM.InventoryActors(class'KFWeapon', W)
    {
        Pair = class'VRWeaponPair'.static.ForMember(W);
        if (Pair != None && Pairs.Find(Pair) == INDEX_NONE) Pairs.AddItem(Pair);
    }
    for (I = 0; I < Pairs.Length; ++I)
        if (!Pairs[I].Restore())
        {
            if (Pairs[I].StockItem != None && !Pairs[I].StockItem.bDeleteMe && Pairs[I].StockItem.InvManager == None)
                Pairs[I].StockItem.Destroy();
            Pairs[I].Destroy();
        }
    foreach IM.InventoryActors(class'KFWeapon', W)
        if (W != IM.HealerWeapon && !W.IsA('KFWeap_Welder')) Remove.AddItem(W);
    for (I = 0; I < Remove.Length; ++I) if (!Remove[I].bDeleteMe) Remove[I].Destroy();
    // A saturated byte counter cannot subtract back to the true weight.
    IM.CurrentCarryBlocks = byte(Clamp(ActualWeight(IM), 0, 255));
    // DefaultInventory still lists the previous perk's spawn weapons.
    Human.DefaultInventory.Length = 0;
    MyKFGI.AddDefaultInventory(Human);
}

function BuildQueue(int I)
{
    local array<class<KFWeapon> > Queue;
    local int J;
    for (J = 0; J < Registry.Weapons.Length; ++J)
        if (BelongsToPerk(Registry.Weapons[J], Players[I].Perk)) Queue.AddItem(Registry.Weapons[J]);
    for (J = 0; J < TraderWeapons.Length; ++J)
        if (Queue.Find(TraderWeapons[J]) == INDEX_NONE && BelongsToPerk(TraderWeapons[J], Players[I].Perk))
            Queue.AddItem(TraderWeapons[J]);
    Players[I].Queue = Queue;
}

// One grant per player per tick, like the local test control, so a full
// arsenal never lands in a single frame.
function GrantStep(int I)
{
    local KFInventoryManager IM;
    local class<KFWeapon> W;
    local bool bOldInfinite;
    IM = KFInventoryManager(Players[I].Pawn.InvManager);
    // Stock carry weight includes unspawned trader transactions; wait them out.
    if (IM.bServerTraderMenuOpen || IM.TransactionItems.Length > 0) return;
    if (Players[I].bStrip)
    {
        Players[I].bStrip = false;
        StripToPerkDefaults(Players[I].Pawn);
        return;
    }
    if (!bCatalogReady) return;
    if (Players[I].Queue.Length == 0 && Players[I].Next == 0) BuildQueue(I);
    if (Players[I].Next < Players[I].Queue.Length)
    {
        W = Players[I].Queue[Players[I].Next];
        ++Players[I].Next;
        // A single whose dual is already carried would split the pair.
        if (Owned(IM, W) || (W.default.DualClass != None && Owned(IM, W.default.DualClass))) return;
        bOldInfinite = IM.bInfiniteWeight;
        IM.bInfiniteWeight = true;
        if (IM.CreateInventory(W, true) != None) ++Players[I].Granted;
        IM.bInfiniteWeight = bOldInfinite;
        return;
    }
    Players[I].bJob = false;
    IM.CurrentCarryBlocks = byte(Clamp(ActualWeight(IM), 0, 255));
    FillAmmo(IM);
    Players[I].PC.ClientMessage("TEST MODE: " $ Players[I].Perk.default.PerkName $ " arsenal granted ("
        $ Players[I].Granted $ " added). Change perk at any time from the perk menu.");
    `log("KF2VR_TEST_MODE loadout player=" $ Players[I].PC.PlayerReplicationInfo.PlayerID
        @ "perk=" $ Players[I].Perk @ "candidates=" $ Players[I].Queue.Length @ "granted=" $ Players[I].Granted);
}

// Full magazines, reserves and grenades, as the stock AllAmmo cheat does.
// VR pair members share a reserve that the pair owns; leave them alone.
function FillAmmo(KFInventoryManager IM)
{
    local KFWeapon W;
    foreach IM.InventoryActors(class'KFWeapon', W)
    {
        if (class'VRWeaponPair'.static.ForMember(W) != None) continue;
        W.AmmoCount[0] = W.MagazineCapacity[0];
        W.AddAmmo(W.GetMaxAmmoAmount(0));
        W.AddSecondaryAmmo(W.MagazineCapacity[1]);
        W.ClientForceAmmoUpdate(W.AmmoCount[0], W.SpareAmmoCount[0]);
    }
    IM.AddGrenades(100);
}

function AdvanceTestMode()
{
    local KFPlayerController PC;
    local KFPawn_Human Human;
    local class<KFPerk> Perk;
    local int I;
    ScanTraderCatalog();
    for (I = Players.Length - 1; I >= 0; --I)
        if (Players[I].PC == None || Players[I].PC.bDeleteMe) Players.Remove(I, 1);
    foreach WorldInfo.AllControllers(class'KFPlayerController', PC)
    {
        if (PC.bDeleteMe || PC.PlayerReplicationInfo == None || PC.PlayerReplicationInfo.bOnlySpectator) continue;
        I = PlayerIndex(PC);
        ApplyPendingPerk(I);
        Perk = PC.GetPerk() != None ? PC.GetPerk().Class : None;
        Human = LivingPawn(PC);
        if (Perk == None) continue;
        if (Human == None)
        {
            // Dead or spectating: the next spawn gets the arsenal.
            Players[I].bJob = false; Players[I].Pawn = None; Players[I].Perk = Perk;
            continue;
        }
        if (Human != Players[I].Pawn)
        {
            Players[I].Pawn = Human; Players[I].Perk = Perk;
            StartJob(I, false);
        }
        else if (Perk != Players[I].Perk)
        {
            Players[I].Perk = Perk;
            StartJob(I, true);
        }
        if (Players[I].bJob) GrantStep(I);
    }
}

function Mutate(string MutateString, PlayerController Sender)
{
    local array<string> Args;
    local KFPlayerController PC;
    local int I;
    ParseStringIntoArray(MutateString, Args, " ", true);
    PC = KFPlayerController(Sender);
    if (bEnabled && PC != None && Args.Length > 0 && Args[0] ~= "kf2vrtest")
    {
        if (Args.Length > 2 && Args[1] ~= "perk")
        {
            // Server PerkList levels are client UI data; only a local player's
            // are real. Remote players use the perk menu, which sends theirs.
            if (!PC.IsLocalController()) PC.ClientMessage("TEST MODE: choose the perk in the perk menu; it applies at once.");
            else if (!SelectPerk(PC, Args[2])) PC.ClientMessage("TEST MODE: unknown perk " $ Args[2]);
        }
        else if (Args.Length > 1 && Args[1] ~= "loadout" && LivingPawn(PC) != None)
        {
            I = PlayerIndex(PC);
            StartJob(I, true);
        }
        else PC.ClientMessage("TEST MODE: mutate kf2vrtest perk <name|index> | mutate kf2vrtest loadout");
    }
    Super.Mutate(MutateString, Sender);
}

defaultproperties
{
    RemoteRole=ROLE_None
}
