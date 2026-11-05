// Melee item 7: only names the stock physics hit reaction that unfixes a
// living Zed's reaction bodies. It carries no impulse of its own; the B&S
// region force in VRPhysicalMelee.ImpactReaction moves them. Never dealt.
class VRDT_ImpactReaction extends KFDT_Bludgeon abstract;

defaultproperties
{
    KDamageImpulse=0
    KDeathUpKick=0
    KDeathVel=0
}
