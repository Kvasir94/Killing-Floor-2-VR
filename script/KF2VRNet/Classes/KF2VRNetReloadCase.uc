// Explicit 9mm diagnostic. Checkpoints observe real authority state; none fire,
// reload, seat ammunition or change ammunition after initial target setup.
class KF2VRNetReloadCase extends Actor;

var KF2VRNetChannel Channel;
var KFWeapon Gun;
var KF2VRNetDiagnosticClot Target;
var int WorldEpoch, ConnectionEpoch, PawnEpoch, ItemId;
var int Stage, InitialAmmo, InitialReserve;
var bool bFailed;
var private int Pending;
var private float Deadline, RequestedAt, PhysicalAt;

replication
{
    if (Role == ROLE_Authority)
        Gun, Target, WorldEpoch, ConnectionEpoch, PawnEpoch, ItemId,
        Stage, InitialAmmo, InitialReserve, bFailed;
}

function Report(name Phase, optional name Reason)
{
    `log("KF2VRNet reload_case role=server phase=" $ Phase $ " reason=" $ Reason
        $ " world=" $ WorldEpoch $ " connection=" $ ConnectionEpoch $ " pawn=" $ PawnEpoch
        $ " item=" $ ItemId $ " hand=1 ammo=" $ Gun.AmmoCount[0]
        $ " reserve=" $ Gun.SpareAmmoCount[0] $ " capacity=" $ Gun.MagazineCapacity[0]
        $ " target=" $ Target.DiagnosticId $ " damage=" $ Target.DamageReceipts
        $ " health=" $ Target.Health $ " held_seconds=" $ (PhysicalAt > 0 ? WorldInfo.RealTimeSeconds - PhysicalAt : 0.0)
        $ " netmode=" $ WorldInfo.NetMode);
}

function Initialize(KF2VRNetChannel C, KFWeapon W, KF2VRNetDiagnosticClot T)
{
    Channel = C; Gun = W; Target = T;
    WorldEpoch = C.WorldEpoch; ConnectionEpoch = C.ConnectionEpoch; PawnEpoch = C.PawnEpoch;
    ItemId = C.ReloadCaseItemId();
    InitialAmmo = W.AmmoCount[0]; InitialReserve = W.SpareAmmoCount[0];
    Deadline = WorldInfo.RealTimeSeconds + 90;
    Report('ready');
    bForceNetUpdate = true;
}

reliable server function ServerCheckpoint(int NextStage)
{
    if (bFailed || Pending != 0 || NextStage != Stage + 1 || NextStage > 5) return;
    Pending = NextStage;
    RequestedAt = WorldInfo.RealTimeSeconds;
}

function Fail(name Reason)
{
    if (bFailed) return;
    bFailed = true; Report('failed', Reason); bForceNetUpdate = true;
}

event Tick(float DeltaTime)
{
    local bool Ready;
    local name Phase;
    local int Loaded;
    if (Role != ROLE_Authority || bFailed || Stage == 5 || Gun == None || Target == None) return;
    if (Channel == None || Channel.WorldEpoch != WorldEpoch || Channel.ConnectionEpoch != ConnectionEpoch
        || Channel.PawnEpoch != PawnEpoch || Channel.HeldState.Human == None || Channel.HeldState.Human.Health <= 0
        || Channel.HeldState.RightWeapon != Gun || Channel.ReloadCaseItemId() != ItemId)
    { Fail('identity-changed'); return; }
    if (WorldInfo.RealTimeSeconds > Deadline || (Pending != 0 && WorldInfo.RealTimeSeconds - RequestedAt > 8))
    { Fail('timeout'); return; }
    // During the physical hold, stock timers must never pay the reload.
    if (Stage == 2 && Pending != 3 && (Gun.AmmoCount[0] != 1 || Gun.SpareAmmoCount[0] != InitialReserve))
    { Fail('unseated-ammo-credit'); return; }
    Loaded = Gun.MagazineCapacity[0] + 1;
    if (Pending == 1)
    {
        Phase = 'shot_before';
        Ready = Gun.AmmoCount[0] == InitialAmmo - 1 && Gun.SpareAmmoCount[0] == InitialReserve
            && Target.DamageReceipts == 1 && Target.Health < Target.HealthMax && Target.Health > 0;
    }
    else if (Pending == 2 || Pending == 3)
    {
        Phase = Pending == 2 ? 'physical' : 'held';
        Ready = Gun.AmmoCount[0] == 1 && Gun.SpareAmmoCount[0] == InitialReserve && Target.DamageReceipts == 1;
        if (Pending == 3) Ready = Ready && WorldInfo.RealTimeSeconds - PhysicalAt >= 4;
    }
    else if (Pending == 4)
    {
        Phase = 'reloaded';
        Ready = Gun.IsInState('Active') && Gun.AmmoCount[0] == Loaded
            && Gun.SpareAmmoCount[0] == InitialReserve - (Loaded - 1) && Target.DamageReceipts == 1;
    }
    else if (Pending == 5)
    {
        Phase = 'shot_after';
        Ready = Gun.IsInState('Active') && Gun.AmmoCount[0] == Loaded - 1
            && Gun.SpareAmmoCount[0] == InitialReserve - (Loaded - 1) && Target.DamageReceipts == 2;
    }
    if (Pending == 0 || !Ready) return;
    Stage = Pending; Pending = 0;
    if (Stage == 2) PhysicalAt = WorldInfo.RealTimeSeconds;
    Report(Phase);
    if (Stage == 5) Report('complete');
    bForceNetUpdate = true;
}

defaultproperties
{
    RemoteRole=ROLE_SimulatedProxy
    bAlwaysRelevant=true
    bReplicateMovement=false
    bCollideActors=false
    bBlockActors=false
    NetUpdateFrequency=10
}
