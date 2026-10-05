// A second independently owned axe. A distinct stock inventory class keeps
// purchase, upgrade, sell, drop and persistent-projectile ownership separate.
// Every tracked interaction accepts the VRWeap_Tomahawk base class.
class VRWeap_TomahawkSecond extends VRWeap_Tomahawk;

simulated function string GetHumanReadableName() { return "RAVEN-7 Additional Axe"; }
