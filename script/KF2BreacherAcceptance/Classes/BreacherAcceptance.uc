// Explicit standalone acceptance fixture. No static optional-content dependency.
// Invoked only by the separate KF2BreacherAcceptance package/mutator.
class BreacherAcceptance extends KFMutator;

var KFPlayerController PC;
var bool bEnabled, bBridge, bPassed;
var int Step, Checks, PerkIndex, ItemIndex;
var float StartedAt, DoshBefore;

function InitMutator(string Options, out string ErrorMessage)
{
    Super.InitMutator(Options, ErrorMessage);
    bEnabled = class'GameInfo'.static.ParseOption(Options, "BreacherAcceptEnabled") == "1";
    bBridge = class'GameInfo'.static.ParseOption(Options, "BreacherAcceptBridge") == "1";
}

event PostBeginPlay()
{
    Super.PostBeginPlay();
    bPassed = true;
    StartedAt = WorldInfo.TimeSeconds;
    `log("BREACHER_ACCEPT rev=1 phase=begin enabled=" $ bEnabled @ "bridge=" $ bBridge);
    SetTimer(0.25, true, 'Advance');
}

function Check(name CaseName, bool Passed)
{
    `log("BREACHER_ACCEPT rev=1 phase=check index=" $ Checks @ "name=" $ CaseName @ "passed=" $ Passed);
    ++Checks;
    bPassed = bPassed && Passed;
}

function Complete()
{
    `log("BREACHER_ACCEPT rev=1 phase=complete checks=" $ Checks @ "passed=" $ bPassed);
    ClearTimer('Advance');
}

function int FindPerk()
{
    local int I;
    for (I=0; I<PC.PerkList.Length; ++I)
        if (PC.PerkList[I].PerkClass.Name == 'BreacherPerk') return I;
    return INDEX_NONE;
}

function int FindItem()
{
    local int I;
    local KFGameReplicationInfo GRI;
    GRI = KFGameReplicationInfo(WorldInfo.GRI);
    if (GRI == None || GRI.TraderItems == None) return INDEX_NONE;
    for (I=0; I<GRI.TraderItems.SaleItems.Length; ++I)
        if (GRI.TraderItems.SaleItems[I].ClassName == 'BreacherDeadbolt') return I;
    return INDEX_NONE;
}

function KFWeapon FindDeadbolt()
{
    local KFWeapon W;
    if (PC.Pawn == None || PC.Pawn.InvManager == None) return None;
    foreach PC.Pawn.InvManager.InventoryActors(class'KFWeapon', W)
        if (W.Class.Name == 'BreacherDeadbolt') return W;
    return None;
}

function Advance()
{
    local KFPlayerController Candidate;
    local KFGFxMenu_Trader Trader;
    local GFxObject Data, Row;
    local Actor A;
    local bool FoundBridge, FoundRow;
    local int I;
    if (WorldInfo.NetMode != NM_Standalone) { Check('standalone_required', false); Complete(); return; }
    if (WorldInfo.TimeSeconds - StartedAt > 90) { Check('timeout', false); Complete(); return; }
    if (PC == None)
        foreach WorldInfo.AllControllers(class'KFPlayerController', Candidate)
            if (Candidate.IsLocalPlayerController()) { PC = Candidate; break; }
    if (PC == None || PC.MyGFxManager == None || PC.PlayerReplicationInfo == None) return;
    if (Step == 0)
    {
        if (WorldInfo.TimeSeconds - StartedAt < 5 || PC.GetPerk() == None || !PC.GetPerk().bInitialized) return;
        foreach WorldInfo.AllActors(class'Actor', A)
            if (A.IsA('VRHandsBridge')) FoundBridge = true;
        if (bBridge && !FoundBridge) return;
        Check('bridge_mode', FoundBridge == bBridge);
        PerkIndex = FindPerk();
        ItemIndex = FindItem();
        if (!bEnabled)
        {
            Check('perk_absent', PerkIndex == INDEX_NONE);
            Check('trader_entry_absent', ItemIndex == INDEX_NONE);
            PerkIndex = PC.SavedPerkIndex;
            Step = 1;
        }
        else
        {
            Check('perk_registered', PerkIndex != INDEX_NONE);
            Check('trader_registered', ItemIndex != INDEX_NONE);
        }
        if (!bPassed) { Complete(); return; }
        Step = 1;
        PC.MyGFxManager.OpenMenu(1); // stock UI_Perks
        return;
    }
    if (Step == 1)
    {
        if (!PC.CanUpdatePerkInfo() || PC.MyGFxManager.PerksMenu == None || PC.MyGFxManager.PerksMenu.SelectionContainer == None) return;
        PC.MyGFxManager.PerksMenu.SelectionContainer.UpdatePerkSelection(PC.SavedPerkIndex);
        Data = PC.MyGFxManager.PerksMenu.SelectionContainer.GetObject("perkData");
        if (Data != None) Row = Data.GetElementObject(PerkIndex);
        if (bEnabled) Check('perk_menu_label', Row != None && Row.GetString("Title") == "Breacher");
        else Check('stock_menu_label', Row != None && Row.GetString("Title") != "Breacher" && Row.GetString("Title") != "");
        PC.MyGFxManager.PerksMenu.SelectionContainer.SavePerk(PerkIndex);
        ++Step; return;
    }
    if (Step == 2)
    {
        if (PC.GetPerk() == None || (PC.GetPerk().Class.Name == 'BreacherPerk') != bEnabled || !PC.GetPerk().bInitialized || PC.MyGFxManager.CurrentMenu == None) return;
        if (bEnabled) Check('perk_selected', true);
        else Check('stock_perk_selected', true);
        PC.MyGFxManager.CurrentMenu.Callback_ReadyClicked(true);
        ++Step; return;
    }
    if (Step == 3)
    {
        if (PC.Pawn == None || PC.Pawn.IsA('KFPawn_Customization') || PC.Pawn.Weapon == None) return;
        if (bEnabled && FindDeadbolt() == None) return;
        if (bEnabled) Check('spawn_starter', PC.Pawn.Health > 0 && PC.GetPerk().Class.Name == 'BreacherPerk');
        else Check('spawn_absence', PC.Pawn.Health > 0 && FindDeadbolt() == None && FindPerk() == INDEX_NONE);
        // Only trader access is forced. Selection, starter, sale and purchase
        // use stock UI/gameplay paths. This does not test reaching a wave trader.
        PC.OpenTraderMenu(true);
        ++Step; return;
    }
    Trader = PC.MyGFxManager.TraderMenu;
    if (Trader == None || PC.MyGFxManager.CurrentMenu != Trader || Trader.ShopContainer == None) return;
    if (Step == 4)
    {
        if (!bEnabled)
        {
            Check('trader_open_absence', FindItem() == INDEX_NONE && FindPerk() == INDEX_NONE);
            PC.CloseTraderMenu();
            PC.ServerSetEnablePurchases(false);
            Complete(); return;
        }
        for (I=0; I<Trader.OwnedItemList.Length; ++I)
            if (Trader.OwnedItemList[I].DefaultItem.ClassName == 'BreacherDeadbolt')
            {
                Trader.Callback_PlayerItemSelected(I);
                Trader.Callback_BuyOrSellItem();
                ++Step; return;
            }
        return;
    }
    if (Step == 5)
    {
        if (FindDeadbolt() != None) return;
        Check('starter_sold', true);
        Trader.Callback_TabChanged(0);
        Trader.Callback_FilterChanged(PerkIndex);
        Data = Trader.ShopContainer.GetObject("shopData");
        if (Data != None)
            for (I=0; I<Data.GetInt("length"); ++I)
            {
                Row = Data.GetElementObject(I);
                if (Row != None && Row.GetInt("itemID") == ItemIndex && Row.GetString("weaponName") == "Deadbolt") FoundRow = true;
            }
        Check('trader_filter_label', Trader.CurrentFilterIndex == PerkIndex && FoundRow);
        Trader.Callback_ShopItemSelected(ItemIndex);
        Check('purchase_available', Trader.bCanBuyOrSellItem);
        DoshBefore = PC.PlayerReplicationInfo.Score;
        Trader.Callback_BuyOrSellItem();
        ++Step; return;
    }
    if (Step == 6)
    {
        if (FindDeadbolt() == None || PC.PlayerReplicationInfo.Score >= DoshBefore) return;
        Check('purchase_inventory', true);
        Check('purchase_charged', PC.PlayerReplicationInfo.Score < DoshBefore);
        PC.CloseTraderMenu();
        PC.ServerSetEnablePurchases(false);
        Complete();
    }
}
