//=============================================================================
// VRBootstrap
//=============================================================================
// Milestone M0 bootstrap mutator. Logging only.
//
// Its entire job is to answer one question with evidence: did the package the
// launch command named actually load, in this build, in this process? The
// research pack is specific about why that needs proving rather than assuming:
//
//   "Confirm the intended package actually loads in logs rather than assuming
//    the launch command succeeded."
//
// So this class changes NOTHING. It adds no actor, alters no inventory, and
// overrides no gameplay hook. Every KFMutator hook it could implement is left
// alone deliberately -- a bootstrap that modified the game would stop being a
// control, and M0's exit evidence requires that the original game still runs.
//
// Search the log for KF2VR_BOOTSTRAP to find its output.
//=============================================================================
class VRBootstrap extends KFMutator;

/** Bumped whenever this file changes, so a stale compiled package is visible
 *  in the log rather than silently passing for a fresh one. */
const BOOTSTRAP_REVISION = 2;

/** Unique, greppable marker. Deliberately not a word that appears anywhere in
 *  the stock logs. */
const LOG_TAG = "KF2VR_BOOTSTRAP";

/** Latches the one-shot chain-alive log. Declared here because UnrealScript
 *  requires all class-scope vars to precede the first function. */
var transient bool bLoggedFirstReplacementCheck;

function InitMutator(string Options, out string ErrorMessage)
{
    super.InitMutator(Options, ErrorMessage);
    LogIdentity("InitMutator");
}

simulated function PostBeginPlay()
{
    super.PostBeginPlay();
    LogIdentity("PostBeginPlay");
}

/**
 * Record who we are and what we loaded into.
 *
 * Everything logged here is observable from script alone. Engine changelist,
 * executable hash and PE architecture are NOT logged, because script cannot
 * see them -- those come from tools/intake/fingerprint.ps1, and inventing them
 * here would produce a confident-looking log line with no evidence behind it.
 */
simulated function LogIdentity(string Phase)
{
    local KFGameInfo KFGI;
    local string NetModeName;

    KFGI = KFGameInfo(WorldInfo.Game);

    switch (WorldInfo.NetMode)
    {
        case NM_Standalone:      NetModeName = "Standalone";      break;
        case NM_DedicatedServer: NetModeName = "DedicatedServer"; break;
        case NM_ListenServer:    NetModeName = "ListenServer";    break;
        case NM_Client:          NetModeName = "Client";          break;
        default:                 NetModeName = "Unknown";         break;
    }

    `log(LOG_TAG @ "phase=" $ Phase
                @ "rev=" $ BOOTSTRAP_REVISION
                @ "class=" $ string(Class)
                @ "package=" $ string(Class.GetPackageName())
                @ "netmode=" $ NetModeName
                @ "map=" $ string(WorldInfo.GetPackageName())
                @ "gameinfo=" $ (KFGI != none ? string(KFGI.Class) : "none")
                @ "time=" $ WorldInfo.TimeSeconds);
}

/**
 * Prove the mutator chain is intact.
 *
 * A mutator that loads but is not linked into the chain will never receive the
 * hooks the VR work eventually needs, and that failure is invisible from the
 * startup log alone.
 */
function bool CheckReplacement(Actor Other)
{
    if (!bLoggedFirstReplacementCheck)
    {
        bLoggedFirstReplacementCheck = true;
        `log(LOG_TAG @ "chain-alive first-CheckReplacement other=" $ string(Other.Class));
    }
    return true;   // replace nothing, ever
}

defaultproperties
{
    // Server-side only: nothing here needs to exist on clients yet, and
    // declaring otherwise would be an unearned replication claim.
    RemoteRole = ROLE_None
}
