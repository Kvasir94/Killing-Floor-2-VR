// Dedicated wording/binding for stock desktop Use. No stock message index is
// relabeled as a pickup, and no HUD/native-art implementation is replaced.
class VRWorldDropPickupMessage extends KFLocalMessage_Interaction;

const PickupMessageIndex = -2;

static function ClientReceive(PlayerController P, optional int Switch,
    optional PlayerReplicationInfo RelatedPRI_1, optional PlayerReplicationInfo RelatedPRI_2,
    optional Object OptionalObject)
{
    local KFGFxMoviePlayer_HUD Hud;
    local KFPlayerInput Input;
    local KeyBind Binding;
    local string Button;
    if (P == None || KFGFxHudWrapper(P.myHUD) == None) return;
    Hud = KFGFxHudWrapper(P.myHUD).HudMovie;
    Input = KFPlayerInput(P.PlayerInput);
    if (Hud == None || Input == None) return;
    Input.GetKeyBindFromCommand(Binding, default.USE_COMMAND, false);
    Button = Input.GetBindDisplayName(Binding);
    // Negative dedicated index is distinct from IMT_None and stays in the
    // stock lowest-priority interaction group. Warning prompts still win.
    Hud.DisplayInteractionMessage("Pick up weapon", PickupMessageIndex, Button, 0.6);
    if (Hud.CurrentInteractionIndex == PickupMessageIndex)
        P.SetTimer(0.6, false, 'HideInteractionMessage', Hud);
}
