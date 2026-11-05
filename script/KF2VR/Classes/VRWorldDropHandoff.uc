// One authority transaction for desktop Use and tracked catches. Geometry and
// permission are checked by the source registry before entering this object.
// Its lifetime follows the registry, including public loot after the donor dies.
class VRWorldDropHandoff extends Object;

var VRWorldDropRegistry Registry;
var bool bCommitting;
var private VRWorldDropRecipient RecipientAdapter;
var private VRWorldDropOwner RecipientLocal;

// A pair extraction replaces the retained wrapper too. Save its held role
// before stock removal retires the old identity, then adopt the exact single.
delegate bool PrepareReplacement(KFWeapon W) { return true; }
delegate FinishReplacement(KFWeapon OldWeapon, KFWeapon NewWeapon) {}

function bool PrepareRecipient(KFPawn_Human P, KFWeapon Existing, int Hand)
{
    local Actor Candidate;
    local VRHandsBridge Bridge;
    RecipientAdapter = None; RecipientLocal = None;
    if (Hand < 0) return IsDesktopPicker(P);
    foreach P.DynamicActors(class'Actor', Candidate, class'VRWorldDropRecipient')
    {
        RecipientAdapter = VRWorldDropRecipient(Candidate);
        if (RecipientAdapter.ReceivesWorldDropPawn(P))
            return RecipientAdapter.PrepareWorldReplacement(Existing);
    }
    RecipientAdapter = None;
    foreach P.DynamicActors(class'VRHandsBridge', Bridge)
        if (Bridge.Role == ROLE_Authority && Bridge.RootBridge == None && Bridge.Human == P
            && Bridge.HandInventory != None && Bridge.HandInventory.WorldDrops != None)
        {
            RecipientLocal = Bridge.HandInventory.WorldDrops;
            return RecipientLocal.PrepareWorldReplacement(Existing);
        }
    return false;
}

function FinishRecipient(VRWorldDropSingleMerge Merge)
{
    if (RecipientAdapter != None)
    {
        RecipientAdapter.RegisterWorldDropPair(Merge.ResultPair);
        RecipientAdapter.FinishWorldReplacement(Merge.RecipientSingle, Merge.RetainedWeapon);
    }
    else if (RecipientLocal != None)
    {
        if (Merge.ResultPair != None) Merge.ResultPair.Hands = RecipientLocal.Inventory;
        RecipientLocal.FinishWorldReplacement(Merge.RecipientSingle, Merge.RetainedWeapon);
    }
    RecipientAdapter = None; RecipientLocal = None;
}

function bool IsDesktopPicker(KFPawn_Human P)
{
    local Actor Candidate;
    local VRHandsBridge Bridge;
    if (!class'VRWorldDropTransfer'.static.ValidBody(P)) return false;
    foreach P.DynamicActors(class'VRHandsBridge', Bridge)
        if (Bridge.RootBridge == None && Bridge.Human == P && Bridge.IsLocalVRContext()) return false;
    foreach P.DynamicActors(class'Actor', Candidate, class'VRTrackedPawnSource')
        if (VRTrackedPawnSource(Candidate).TracksPawn(P)) return false;
    return true;
}

function KFWeapon TransferHeldWeapon(KFPawn_Human OriginalOwner, KFPawn_Human Catcher,
    KFWeapon W, int Hand, byte GripRole, vector RootPosition, quat RootRotation)
{
    local VRWorldDropGun Prop, RetainedProp;
    local VRWorldDropTransfer Ordinary;
    local VRWorldDropPairTransfer Extraction;
    local VRWorldDropSingleMerge Merge;
    local VRWeaponPair Pair;
    local KFWeapon ResultWeapon, Retained;
    local byte Outcome;
    local int I;
    if (bCommitting || Registry == None || Registry.Host == None
        || Registry.Host.Role != ROLE_Authority || GripRole > 1 || Hand < -1 || Hand > 1
        || (Hand == -1 && !IsDesktopPicker(Catcher))) return None;
    Prop = Registry.Find(W);
    if (Prop == None || !Prop.bCatchPending || Prop.SourceRegistry != Registry
        || Prop.OwnedWeapon != W) return None;
    // Same-owner desktop adoption does not remove/re-add the inventory actor.
    if (OriginalOwner == Catcher && !Prop.bPublic)
    {
        if (Hand != -1 || !class'VRWorldDropTransfer'.static.AdoptOwned(Catcher, W)) return None;
        return W;
    }
    bCommitting = true;
    Pair = class'VRWeaponPair'.static.ForMember(W);
    if (Pair != None && !Prop.bPublic)
    {
        I = Pair.PhysicalMemberIndex(W);
        if (I >= 0)
        {
            Retained = Pair.Members[1 - I];
            RetainedProp = Registry.Find(Retained);
            Extraction = new(self) class'VRWorldDropPairTransfer';
            if (Extraction.Prepare(Pair, W, Catcher, Pair.WorldDropReserve[I],
                Pair.Reserve + Pair.WorldDropReserve[1 - I], Pair.WorldDropUpgrade[I], Pair.WorldDropUpgrade[1 - I], Hand >= 0)
                && PrepareReplacement(Retained))
            {
                Merge = Extraction.PreparedMerge;
                if (Merge != None && !PrepareRecipient(Catcher, Merge.RecipientSingle, Hand))
                {
                    FinishReplacement(Retained, None);
                    Extraction.Cancel(); bCommitting = false; return None;
                }
                Extraction.CommitExtraction = Pair.CommitWorldExtraction;
                if (RetainedProp != None) RetainedProp.bCatchPending = true;
                Outcome = Extraction.Commit();
                if (Outcome == class'VRWorldDropPairTransfer'.const.Transferred)
                {
                    if (RetainedProp != None) Registry.ReplaceWeaponIdentity(Retained, Extraction.KeptWeapon);
                    FinishReplacement(Retained, Extraction.KeptWeapon);
                    if (Merge != None) FinishRecipient(Merge);
                    ResultWeapon = Extraction.CaughtWeapon;
                }
                else
                {
                    FinishReplacement(Retained, None);
                    if (Merge != None) FinishRecipient(Merge);
                }
                if (RetainedProp != None) RetainedProp.bCatchPending = false;
            }
            Extraction.Cancel();
        }
    }
    else
    {
        Ordinary = new(self) class'VRWorldDropTransfer';
        if ((Prop.bPublic && Ordinary.PreparePublic(Prop, Catcher))
            || (!Prop.bPublic && Ordinary.Prepare(OriginalOwner, Catcher, W)))
        {
            Outcome = Ordinary.Commit(Hand >= 0);
            if (Outcome == class'VRWorldDropTransfer'.const.Transferred) ResultWeapon = W;
        }
        else
        {
            Merge = new(self) class'VRWorldDropSingleMerge';
            if (Merge.Prepare(Catcher, W, Prop.bPublic ? None : OriginalOwner, Hand >= 0, Prop.bPublic ? Prop : None)
                && PrepareRecipient(Catcher, Merge.RecipientSingle, Hand))
            {
                Outcome = Merge.Commit();
                if (Outcome == class'VRWorldDropSingleMerge'.const.Transferred)
                {
                    FinishRecipient(Merge);
                    ResultWeapon = Merge.ResultWeapon;
                }
                else FinishRecipient(Merge);
            }
            Merge.Cancel();
        }
        Ordinary.Cancel();
    }
    if (ResultWeapon != None && Hand == -1) class'VRWorldDropTransfer'.static.AdoptOwned(Catcher, ResultWeapon);
    bCommitting = false;
    return ResultWeapon;
}
