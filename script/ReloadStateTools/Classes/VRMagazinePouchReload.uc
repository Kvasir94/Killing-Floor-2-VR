// Nonshipping external observation adapter. All admission, authored geometry,
// guide state, removal receipts, reservation, stock payment and finish are real.
class VRMagazinePouchReload extends VRInteractiveReload;

var vector SamplePosition;
var quat SampleRotation;
var float SampleTime;
var bool bSampleBeltContact;

function vector HeldLocation() { return SamplePosition; }
function quat HeldQuat() { return SampleRotation; }
function float Now() { return SampleTime; }

function int ReturnPouchSide(int Hand, bool Held, out byte Armed)
{
    if (bSampleBeltContact) { Armed = 1; return 0; }
    return super.ReturnPouchSide(Hand, Held, Armed);
}

function SamplePath(float Fraction)
{
    StockInsertPose(Fraction, SamplePosition, SampleRotation);
    SampleTime += 1.0 / 120.0;
}
