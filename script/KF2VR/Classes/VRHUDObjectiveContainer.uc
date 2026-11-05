// The shipped SWF may omit objectiveNumberMC. Preserve stock objective state,
// progress, visibility and sound behavior; hide that optional child only if present.
class VRHUDObjectiveContainer extends KFGFxHUD_ObjectiveConatiner;

simulated function SetActive(bool bActive)
{
    local GFxObject Number;
    local PlayerController OwnerPC;
    if (bActive)
    {
        OwnerPC = GetPC();
        if (OwnerPC != None && OwnerPC.WorldInfo != None
            && KFGameReplicationInfo(OwnerPC.WorldInfo.GRI) != None)
        {
            Super.SetActive(true);
            return;
        }
    }
    SetVisible(false);
    CurrentObjectiveInterface = None;
    Number = GetObject("objectiveNumberMC");
    if (Number != None) Number.SetVisible(false);
}
