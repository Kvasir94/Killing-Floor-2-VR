// Manual range services. Never instantiated by normal game modes.
class VRRangeDirector extends Actor;
var VRLocalTestRegistry Registry;
var array<KFPawn_Monster> RangeZeds;
var array<KFPawn_Human> MoneyUsers, AmmoUsers;
var bool bActiveAI;
var int ButtonCount;
var VRRangeButton StatusButton;

event PostBeginPlay()
{
    local int I;
    local vector At;
    local rotator Facing;
    local VRRangeRack Rack;
    Super.PostBeginPlay();
    if(Role != ROLE_Authority) return;
    Registry=new(self) class'VRLocalTestRegistry'; Registry.Build();
    // Coordinates match the SDK/Blender layout. VRHUDPanel displays its -X
    // face, so rotations below point that face into the occupied station.
    AddSign("VR ARMORY",vect(-2070,200,330),rot(0,32768,0));
    AddSign("LIVE FIRE",vect(700,500,330),rot(0,16384,0));
    AddSign("ZED ARENA",vect(500,2450,350),rot(0,16384,0));
    AddSign("RELOAD BENCH",vect(-500,-1750,260),rot(0,-16384,0));
    AddSign("PARTNER LAB",vect(-900,-1750,280),rot(0,-16384,0));
    AddSign("CATCH PRACTICE",vect(900,-1750,280),rot(0,-16384,0));
    AddSign("MOVEMENT / REACH",vect(2200,-1750,350),rot(0,-16384,0));
    for(I=0;I<4;++I)
    {
        At.X=1000+I*500; At.Y=-435; At.Z=10;
        AddSign(string(5+I*5)$" m",At,rot(-16384,0,0));
    }
    for(I=0;I<Registry.Weapons.Length;++I)
    {
        if(I<50)
        { At.X=-2100; At.Y=-1400+(I%25)*130; At.Z=85+(I/25)*85; Facing=rot(0,0,0); }
        else if(I<120)
        { At.X=-2000+((I-50)%35)*130; At.Y=2450; At.Z=85+((I-50)/35)*85; Facing=rot(0,-16384,0); }
        else
        { At.X=2800; At.Y=700+((I-120)%12)*130; At.Z=85+((I-120)/12)*85; Facing=rot(0,32768,0); }
        Rack=Spawn(class'VRRangeRack',self,,At,Facing);
        if(Rack != None) Rack.Configure(Registry.Weapons[I]);
    }
    AddButton('Trader',"","OPEN TRADER");
    AddButton('Money',"","INFINITE MONEY");
    AddButton('Ammo',"","INFINITE RESERVE AMMO");
    AddButton('Heal',"","HEAL + ARMOR");
    AddButton('ToggleAI',"","ZED AI ON / OFF");
    AddButton('ClearZeds',"","CLEAR ZEDS");
    AddButton('ClearGuns',"","CLEAR DROPPED GUNS");
    AddButton('ClearMags',"","CLEAR LOOSE MAGS");
    AddButton('ClearDummy',"","CLEAR DUMMY");
    AddButton('Reset',"","RESET RANGE");
    AddButton('FreshMag',"","SPAWN FULL MAG");
    AddButton('PartialMag',"","SPAWN PART USED MAG");
    AddButton('RespawnDummy',"","RESPAWN DUMMY");
    AddButton('HoldPose',"","DUMMY COPY POSE + GUNS");
    AddButton('Record',"","RECORD MY ACTIONS");
    AddButton('StopRecord',"","STOP RECORDING");
    AddButton('Play',"","DUMMY PLAY ACTIONS");
    AddButton('TossUp',"","TOSS PROP UP");
    AddButton('TossToward',"","TOSS PROP TO ME");
    AddButton('TossSlow',"","TOSS SPEED SLOW");
    AddButton('TossFast',"","TOSS SPEED FAST");
    AddButton('TossRepeat',"","REPEAT TOSS");
    AddButton('TossStop',"","STOP TOSS");
    AddButton('SpawnZed',"cyst","SPAWN CYST");
    AddButton('SpawnZed',"alpha","SPAWN ALPHA");
    AddButton('SpawnZed',"slasher","SPAWN SLASHER");
    AddButton('SpawnZed',"crawler","SPAWN CRAWLER");
    AddButton('SpawnZed',"gorefast","SPAWN GOREFAST");
    AddButton('SpawnZed',"bloat","SPAWN BLOAT");
    AddButton('SpawnZed',"husk","SPAWN HUSK");
    AddButton('SpawnZed',"scrake","SPAWN SCRAKE");
    AddButton('SpawnZed',"fleshpound","SPAWN FLESHPOUND");
    for(I=0;I<Registry.Perks.Length;++I)
    {
        AddButton('SetPerk',string(I),"PERK " $ Registry.Perks[I].default.PerkName);
        AddButton('GrantPerk',string(I),"GUNS " $ Registry.Perks[I].default.PerkName);
    }
    StatusButton=AddButton('Status',"","RANGE READY");
    if(StatusButton != None) StatusButton.SetLocation(vect(-1500,-1750,245));
    SetTimer(0.5,true,'MaintainRange');
}

function AddSign(string Caption,vector At,rotator Facing)
{
    local VRRangeSign Sign;
    Sign=Spawn(class'VRRangeSign',self,,At,Facing);
    if(Sign!=None) Sign.Configure(Caption);
}

function VRRangeButton AddButton(name Action,string Argument,string Caption)
{
    local VRRangeButton B;
    local vector At;
    At.X=-1700+(ButtonCount%26)*160; At.Y=-1750; At.Z=115+(ButtonCount/26)*65;
    B=Spawn(class'VRRangeButton',self,,At,rot(0,-16384,0));
    if(B != None) { B.Action=Action; B.Tag=Action; B.Argument=Argument; B.Caption=Caption; }
    ++ButtonCount;
    return B;
}

function ClampWeight(KFInventoryManager IM)
{
    local Inventory Item;
    local KFWeapon W;
    local int Weight, Count;
    Item=IM.InventoryChain;
    while(Item != None && Count++<256)
    {
        W=KFWeapon(Item);
        if(W != None) Weight+=Max(0,W.static.GetDefaultModifiedWeightValue(W.CurrentWeaponUpgradeIndex));
        Item=Item.Inventory;
    }
    IM.CurrentCarryBlocks=byte(Clamp(Weight,0,255));
}
function ClearZeds()
{
    local int I;
    for(I=0;I<RangeZeds.Length;++I) if(RangeZeds[I] != None)
    { if(RangeZeds[I].Controller != None) RangeZeds[I].Controller.Destroy(); RangeZeds[I].Destroy(); }
    RangeZeds.Length=0;
}
function ClearGuns()
{
    local VRWorldDropGun G;
    local KFDroppedPickup P;
    foreach WorldInfo.DynamicActors(class'VRWorldDropGun',G)
    {
        if(G.SourceRegistry != None) G.SourceRegistry.Retire(G,3);
        G.Destroy();
    }
    foreach WorldInfo.DynamicActors(class'KFDroppedPickup',P)
        if(VRWorldDropGun(P) == None) P.Destroy();
}
function ApplyAI(KFPawn_Monster Zed,KFPawn_Human Human)
{
    local KFAIController AI;
    if(!bActiveAI) { if(Zed.Controller != None) Zed.Controller.Destroy(); Zed.Acceleration=vect(0,0,0); return; }
    if(Zed.Controller == None) Zed.SpawnDefaultController();
    AI=KFAIController(Zed.Controller);
    if(AI != None) { AI.SetTeam(1); AI.SetEnemy(Human); }
}
function SpawnZed(string Kind,KFPawn_Human Human)
{
    local class<KFPawn_Monster> ZedClass;
    local KFPawn_Monster Zed;
    local vector At;
    if(RangeZeds.Length>=24) { KFPlayerController(Human.Controller).ClientMessage("Range limit: clear zeds before spawning more."); return; }
    ZedClass=Registry.ZedClass(Kind); if(ZedClass == None) return;
    At.X=600+(RangeZeds.Length%6)*220; At.Y=1200+(RangeZeds.Length/6)*220;
    At.Z=ZedClass.default.CylinderComponent.CollisionHeight+5;
    Zed=Spawn(ZedClass,self,,At,rot(0,-16384,0));
    if(Zed != None) { Zed.bDebug_SpawnedThroughCheat=true; Zed.SetPhysics(PHYS_Falling); RangeZeds.AddItem(Zed); ApplyAI(Zed,Human); }
}
function ToggleUser(out array<KFPawn_Human> Users,KFPawn_Human Human)
{
    local int I;
    I=Users.Find(Human); if(I == INDEX_NONE) Users.AddItem(Human); else Users.Remove(I,1);
}
function Activate(VRRangeButton B,KFPawn_Human Human)
{
    local KFPlayerController PC;
    local KFInventoryManager IM;
    local VRRangePracticeBase Practice;
    local int I,Index;
    local bool OldWeight;
    if(Role != ROLE_Authority || Human == None || Human.Health<=0) return;
    PC=KFPlayerController(Human.Controller); IM=KFInventoryManager(Human.InvManager);
    if(PC == None || IM == None) return;
    Index=int(B.Argument);
    switch(B.Action)
    {
        case 'Trader': PC.OpenTraderMenu(true); break;
        case 'Money': ToggleUser(MoneyUsers,Human); break;
        case 'Ammo': ToggleUser(AmmoUsers,Human); break;
        case 'Heal': Human.Health=Human.HealthMax; Human.Armor=100; break;
        case 'GrantPerk':
            if(Index<0 || Index>=Registry.Perks.Length || IM.bServerTraderMenuOpen || IM.TransactionItems.Length>0) break;
            OldWeight=IM.bInfiniteWeight; IM.bInfiniteWeight=true;
            for(I=0;I<Registry.Weapons.Length;++I)
                if(Registry.Matches(Registry.Weapons[I],string(Registry.Perks[Index].Name)) && !Registry.AlreadyOwned(IM,Registry.Weapons[I]))
                    IM.CreateInventory(Registry.Weapons[I],true);
            IM.bInfiniteWeight=OldWeight;
            ClampWeight(IM);
            PC.ClientMessage("Range class weapons granted; inventory capacity bypassed for this grant.");
            break;
        case 'SetPerk':
            if(Index<0 || Index>=Registry.Perks.Length || IM.bServerTraderMenuOpen || IM.TransactionItems.Length>0) break;
            I=PC.PerkList.Find('PerkClass',Registry.Perks[Index]); if(I == INDEX_NONE) break;
            PC.ServPendingPerkClass=Registry.Perks[Index];
            PC.ServPendingPerkLevel=PC.PerkList[I].PerkLevel;
            PC.ServPendingPerkPrestigeLevel=PC.PerkList[I].PrestigeLevel;
            PC.ServPendingPerkBuild=PC.GetPerkBuildByPerkClass(Registry.Perks[Index]);
            PC.ApplyPendingPerks(); break;
        case 'SpawnZed': SpawnZed(B.Argument,Human); break;
        case 'ToggleAI': bActiveAI=!bActiveAI;
            for(I=0;I<RangeZeds.Length;++I) if(RangeZeds[I] != None && RangeZeds[I].Health>0) ApplyAI(RangeZeds[I],Human);
            break;
        case 'ClearZeds': ClearZeds(); break;
        case 'ClearGuns': ClearGuns(); break;
        case 'Reset': ClearZeds(); ClearGuns(); bActiveAI=false; MoneyUsers.Length=0; AmmoUsers.Length=0;
        default:
            foreach WorldInfo.DynamicActors(class'VRRangePracticeBase',Practice) if(Practice.Tag == 'VRRangePractice') Practice.Trigger(B,Human);
            break;
    }
    MaintainRange();
}
function MaintainRange()
{
    local int I,J;
    local Inventory Inv;
    local KFWeapon W;
    local VRRangePracticeBase Practice;
    local string PracticeStatus;
    for(I=MoneyUsers.Length-1;I>=0;--I)
        if(MoneyUsers[I] == None || MoneyUsers[I].Health<=0) MoneyUsers.Remove(I,1);
        else if(MoneyUsers[I].PlayerReplicationInfo != None) MoneyUsers[I].PlayerReplicationInfo.Score=100000;
    for(I=AmmoUsers.Length-1;I>=0;--I)
    {
        if(AmmoUsers[I] == None || AmmoUsers[I].Health<=0) { AmmoUsers.Remove(I,1); continue; }
        if(AmmoUsers[I].InvManager == None) continue;
        Inv=AmmoUsers[I].InvManager.InventoryChain; J=0;
        while(Inv != None && J++<256)
        {
            W=KFWeapon(Inv); if(W != None) { W.SpareAmmoCount[0]=W.SpareAmmoCapacity[0]; W.SpareAmmoCount[1]=W.SpareAmmoCapacity[1]; }
            Inv=Inv.Inventory;
        }
    }
    for(I=RangeZeds.Length-1;I>=0;--I)
        if(RangeZeds[I] == None || RangeZeds[I].bDeleteMe) RangeZeds.Remove(I,1);
    foreach WorldInfo.DynamicActors(class'VRRangePracticeBase',Practice) if(Practice.Tag == 'VRRangePractice') PracticeStatus=Practice.StatusText;
    if(StatusButton != None) StatusButton.Caption="AI " $ (bActiveAI ? "ON" : "OFF") $ " | ZEDS " $ RangeZeds.Length
        $ " | MONEY " $ MoneyUsers.Length $ " AMMO " $ AmmoUsers.Length $ " | " $ PracticeStatus;
}
defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
}










