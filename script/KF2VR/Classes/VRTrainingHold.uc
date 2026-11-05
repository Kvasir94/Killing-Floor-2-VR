// Solo only: the authority side of VR Training. It holds the Survival wave
// while training runs (the same suspended-wave state Practice uses, but it
// never enables cheats, so the match stays ranked and keeps its XP), lends
// the base guns for the weapon drills, spawns VRTrainingClot targets (no XP
// or dosh) and calls Zed Time for the moments worth slowing down. Zeds alive
// when the hold starts are removed with no killer, as the stock KillZeds cheat
// does; ending the hold returns every loan, clears the targets and resumes
// the wave. Online the server owns waves and zeds and nothing here runs.
class VRTrainingHold extends Actor;

var KFGameInfo_Survival Game;   // None on the VR range: no waves to hold
var KFGameInfo AnyGame;
var KFPlayerController PC;
var bool bHeld;
var array<KFPawn_Monster> Targets;
var int KillsTaken;
// Loans: the gun and whether the player owned it before (kept, ammo restored).
struct Loan
{
    var KFWeapon Gun;
    var bool bOwned;
    var int SavedAmmo, SavedSpare;
};
var array<Loan> Loans;
var int SavedCarryBlocks;
var bool bCarrySaved;

function bool BeginHold(KFPlayerController NewPC)
{
    if (WorldInfo.NetMode != NM_Standalone || NewPC == None) return false;
    PC = NewPC;
    AnyGame = KFGameInfo(WorldInfo.Game);
    Game = KFGameInfo_Survival(AnyGame);
    return AnyGame != None;
}

// Retried every tick: training can start in trader time or before the first
// wave, and the hold takes effect as soon as a normal wave is playing.
event Tick(float DeltaTime)
{
    Super.Tick(DeltaTime);
    if (bHeld || Game == None || !Game.IsInState('PlayingWave')) return;
    if (Game.MyKFGRI == None || Game.MyKFGRI.IsBossWave()) return;
    // Push/pop, as Practice does: PlayingWave.BeginState would start another wave.
    Game.PushState('DebugSuspendWave');
    bHeld = Game.IsInState('DebugSuspendWave');
    if (!bHeld) return;
    // PushState skips DebugSuspendWave.BeginState, so clear the field here.
    ClearZeds();
    `log("KF2VR_TRAINING wave held");
}

function ClearZeds()
{
    local KFPawn_Monster Zed;
    foreach WorldInfo.AllPawns(class'KFPawn_Monster', Zed)
        if (Zed.IsAliveAndWell() && PlayerController(Zed.Controller) == None && Targets.Find(Zed) == INDEX_NONE)
            Zed.Died(None, None, Zed.Location);
}

// ------------------------------------------------------------ loans

function KFWeapon Lend(name ClassName, int StartRounds)
{
    local KFInventoryManager Inv;
    local KFWeapon W;
    local class<KFWeapon> WeaponClass;
    local Loan Entry;
    local int Rounds;
    if (PC == None || PC.Pawn == None) return None;
    Inv = KFInventoryManager(PC.Pawn.InvManager);
    if (Inv == None) return None;
    foreach Inv.InventoryActors(class'KFWeapon', W)
        if (W.Class.Name == ClassName) break;
    if (W != None && W.Class.Name == ClassName)
    {
        Entry.bOwned = true;
        Entry.SavedAmmo = W.AmmoCount[0];
        Entry.SavedSpare = W.SpareAmmoCount[0];
    }
    else
    {
        W = None;
        WeaponClass = class<KFWeapon>(DynamicLoadObject("KFGameContent." $ ClassName, class'Class', true));
        if (WeaponClass == None) return None;
        if (!bCarrySaved) { SavedCarryBlocks = Inv.MaxCarryBlocks; bCarrySaved = true; }
        Inv.MaxCarryBlocks = Max(Inv.MaxCarryBlocks, Inv.CurrentCarryBlocks + WeaponClass.static.GetDefaultModifiedWeightValue(0));
        W = KFWeapon(Inv.CreateInventory(WeaponClass, true));
        if (W == None) return None;
    }
    W.Class.static.TriggerAsyncContentLoad(W.Class);
    // A short magazine so the drill reaches its reload quickly, and a full
    // reserve so the reload always has something to load.
    Rounds = Clamp(StartRounds, 1, W.MagazineCapacity[0]);
    W.AmmoCount[0] = Rounds;
    W.SpareAmmoCount[0] = Max(W.SpareAmmoCount[0], W.GetMaxAmmoAmount(0) - Rounds);
    Entry.Gun = W;
    Loans.AddItem(Entry);
    `log("KF2VR_TRAINING lend gun=" $ ClassName $ " owned=" $ Entry.bOwned $ " rounds=" $ Rounds);
    return W;
}

function ReturnLoans()
{
    local int I;
    local KFWeapon W;
    local KFInventoryManager Inv;
    Inv = (PC != None && PC.Pawn != None) ? KFInventoryManager(PC.Pawn.InvManager) : None;
    for (I = 0; I < Loans.Length; ++I)
    {
        W = Loans[I].Gun;
        if (W == None || W.bDeleteMe) continue;
        if (Loans[I].bOwned)
        {
            W.AmmoCount[0] = Loans[I].SavedAmmo;
            W.SpareAmmoCount[0] = Loans[I].SavedSpare;
            continue;
        }
        if (Inv != None && W.Owner == PC.Pawn) Inv.RemoveFromInventory(W);
        W.Destroy();
    }
    Loans.Length = 0;
    if (bCarrySaved && Inv != None) Inv.MaxCarryBlocks = SavedCarryBlocks;
    bCarrySaved = false;
}

// ------------------------------------------------------------ targets

function int SpawnTargets(int Count, float Distance, float Spread)
{
    local int I, Made;
    local vector Position;
    local rotator Facing;
    local VRTrainingClot Target;
    local KFAIController AI;
    for (I = 0; I < Count; ++I)
    {
        if (!FindSpawnPosition(Distance + (I % 2) * 60, (I - (Count - 1) * 0.5) * Spread, Position, Facing)) continue;
        Target = Spawn(class'VRTrainingClot', self,, Position, Facing);
        if (Target == None) continue;
        Target.bDebug_SpawnedThroughCheat = true;
        Target.SetPhysics(PHYS_Falling);
        Target.SpawnDefaultController();
        AI = KFAIController(Target.Controller);
        if (AI == None) { Target.Destroy(); continue; }
        AI.SetTeam(1);
        // Passive, as Practice's dummies: they stand and take hits.
        AI.BeginDebugCommand();
        AI.DefaultCommandClass = class'AICommand_Debug';
        AI.MeleeCommandClass = class'AICommand_Debug';
        Targets.AddItem(Target);
        Made++;
    }
    return Made;
}

function bool FindSpawnPosition(float Distance, float Side, out vector Position, out rotator Facing)
{
    local vector Start, Direction, Right, Floor, HitLocation, HitNormal;
    local rotator View;
    local float Try;
    if (PC == None || PC.Pawn == None) return false;
    PC.GetPlayerViewPoint(Start, View);
    View.Pitch = 0; View.Roll = 0;
    Direction = vector(View);
    Right = vector(View + rot(0, 16384, 0));
    // Walk the spot in toward the player until the floor is open and visible.
    for (Try = Distance; Try >= 200; Try -= 100)
    {
        Floor = PC.Pawn.Location + Direction * Try + Right * Side + vect(0,0,100);
        if (Trace(HitLocation, HitNormal, Floor, PC.Pawn.Location, false) != None) continue;
        if (Trace(HitLocation, HitNormal, Floor - vect(0,0,500), Floor, false) == None || HitNormal.Z < 0.65) continue;
        Position = HitLocation + vect(0,0,1) * (class'VRTrainingClot'.default.CylinderComponent.CollisionHeight + 3);
        Facing = View;
        Facing.Yaw += 32768;
        return true;
    }
    return false;
}

function int LiveTargets()
{
    local int I, N;
    for (I = Targets.Length - 1; I >= 0; --I)
    {
        if (Targets[I] == None || Targets[I].bDeleteMe) { Targets.Remove(I, 1); KillsTaken++; continue; }
        if (Targets[I].IsAliveAndWell()) N++;
    }
    return N;
}

// Testers and scripted replays: drop every live target as if shot (no XP).
function KillTargets()
{
    local int I;
    for (I = 0; I < Targets.Length; ++I)
        if (Targets[I] != None && Targets[I].IsAliveAndWell()) Targets[I].Died(None, None, Targets[I].Location);
}

function ClearTargets()
{
    local int I;
    for (I = 0; I < Targets.Length; ++I)
        if (Targets[I] != None && !Targets[I].bDeleteMe) Targets[I].Destroy();
    Targets.Length = 0;
}

function ZedTime(float Duration)
{
    if (AnyGame != None) AnyGame.DramaticEvent(1.0, Duration);
}

function EndHold()
{
    ReturnLoans();
    ClearTargets();
    if (bHeld && Game != None && Game.IsInState('DebugSuspendWave'))
    {
        Game.PopState();
        Game.CheckWaveEnd();
        `log("KF2VR_TRAINING wave resumed");
    }
    bHeld = false;
    Game = None; AnyGame = None;
    Destroy();
}

defaultproperties
{
    RemoteRole=ROLE_None
    bHidden=true
    bCollideActors=false
    bBlockActors=false
}
