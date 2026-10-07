#include "HeadAim.h"
#include <DirectXMath.h>
#include <cmath>
#include <limits>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include "kf2vr/Basis.h"

using namespace kf2vr;
using namespace kf2vr::adapter;
namespace dx = DirectX;
static void Check(bool condition, const char* message) {
    if (!condition) throw std::runtime_error(message);
}
static bool Near(float a, float b, float tolerance = 0.0002f) { return std::abs(a-b) < tolerance; }
static bool NearUnits(int a, int b) { return std::abs(a-b) <= 1; }
static pinned::NativeMatrix4 Matrix(dx::FXMMATRIX matrix) {
    dx::XMFLOAT4X4 stored; dx::XMStoreFloat4x4(&stored, matrix);
    pinned::NativeMatrix4 result; std::memcpy(result.m, &stored, sizeof(stored)); return result;
}
static dx::XMMATRIX Rotation(Quat q) {
    return dx::XMMatrixRotationQuaternion(dx::XMVectorSet(q.x,q.y,q.z,q.w));
}
static void Equal(const pinned::NativeMatrix4& a, const pinned::NativeMatrix4& b) {
    for(int r=0;r<4;++r) for(int c=0;c<4;++c)
        Check(Near(a.m[r][c],b.m[r][c],0.002f), "residual matrices must match one head application");
}
static xr::FrameState Frame(std::uint64_t sample, float yaw = 0, float pitch = 0, float roll = 0) {
    xr::FrameState f;
    f.poseSampleId=sample; f.state=xr::SessionState::Focused;
    f.shouldRender=f.viewsValid=f.headPoseValid=f.headPoseTracked=true;
    f.head.rot=(Quat::FromAxisAngle({0,1,0},yaw)*Quat::FromAxisAngle({1,0,0},pitch)*
                Quat::FromAxisAngle({0,0,1},roll)).Normalized();
    f.eyeLeft.poseValid=f.eyeRight.poseValid=true;
    f.eyeLeft.pose={f.head.rot,f.head.rot.Rotate({-0.032f,0,0})};
    f.eyeRight.pose={f.head.rot,f.head.rot.Rotate({0.032f,0,0})};
    f.eyeLeft.fov={-0.85f,0.7f,0.8f,-0.65f};
    f.eyeRight.fov={-0.7f,0.85f,0.8f,-0.65f};
    return f;
}
int main() {
    try {
        // Independently verify native rotator signs against UE3 actor axes.
        auto v=NativeActorRotation({16384,0,0}).Rotate({1,0,0});
        Check(Near(v.z,1), "positive native pitch aims up");
        v=NativeActorRotation({0,16384,0}).Rotate({1,0,0});
        Check(Near(v.y,1), "positive native yaw aims right");
        v=NativeActorRotation({0,0,16384}).Rotate({0,1,0});
        Check(Near(v.z,-1), "native roll sign");

        {
            // Floor match: a 1.75 m standing eye in STAGE space renders at its
            // real height above the pawn floor, capped 12 cm over the pawn eye.
            HeadAim floor; HeadAimRequest r; pinned::NativeRotator c{0,0,0};
            auto f=Frame(1); f.head.pos={0,1.60f,0};
            Check(floor.Prepare(0x99,c,f,r)==HeadAimStatus::ReferenceEstablished,"floor reference");
            floor.SetFloorEye(1.54f);
            AppliedHeadAim a; Check(floor.RenderState(0x99,c,a),"floor render state");
            Check(Near(f.head.pos.y-a.reference.pos.y,0.06f),"1.60 m eye sits 6 cm over a 1.54 m pawn eye");
            Check(Near(floor.StandingHeight(),1.60f),"captured height is unshifted");
            floor.SetFloorEye(1.30f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,HeadAim::kMaxFloorLift),"tall lift capped");
            floor.SetFloorEye(2.20f);
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y-f.head.pos.y,HeadAim::kMaxFloorDrop),"short drop capped");
            floor.SetFloorEye(0);
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y,1.60f),"zero restores the fixed eye");
            floor.SetFloorEye(0,.10f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,.10f),
                "seated offset raises the fixed view by ten centimetres without STAGE");
            const Vec3 hand{.2f,1.10f,-.4f};
            Check(Near((hand-a.reference.pos).y,-.40f),"hand shares the seated view's ten centimetre lift");
            floor.SetFloorEye(0,.10f);
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y,1.50f),"repeated seated setting does not accumulate");
            Check(Near(floor.StandingHeight(),1.60f),"seated adjustment does not recapture physical height");
            floor.SetFloorEye(0,1.f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,.12f),"seated lift capped at twelve centimetres");
            floor.SetFloorEye(0,-1.f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,-.40f),"seated drop capped at forty centimetres");
            floor.SetFloorEye(1.54f,.10f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,.06f),"standing floor matching takes precedence over seated offset");
            floor.SetFloorEye(0,std::numeric_limits<float>::quiet_NaN());
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y,1.60f),"invalid seated offset restores fixed eye");
            floor.SetFloorEye(0,std::numeric_limits<float>::infinity());
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y,1.60f),"infinite seated offset rejected");
            floor.Reset();
            f=Frame(2); f.head.pos={0,.90f,0};
            Check(floor.Prepare(0x99,c,f,r)==HeadAimStatus::ReferenceEstablished,"seated recapture at new physical height");
            floor.SetFloorEye(0,.10f);
            Check(floor.RenderState(0x99,c,a) && Near(f.head.pos.y-a.reference.pos.y,.10f),"saved seated offset reapplies once after recapture");
            floor.SetFloorEye(0);
            Check(floor.RenderState(0x99,c,a) && Near(a.reference.pos.y,.90f),"reset height restores the newly captured fixed eye");
        }
        constexpr std::uintptr_t controller=0x1234;
        {
            // Stock map teleports replace the controller with a destination
            // rotator while the HMD contribution is still in our bookkeeping.
            HeadAim transition; HeadAimRequest r;
            pinned::NativeRotator c{0,7000,0}, corrected{};
            auto f=Frame(1); f.head.pos={1,1.60f,3};
            Check(!transition.WorldUpTransition(controller,c,corrected),"transition requires an established reference");
            Check(transition.Prepare(controller,c,f,r)==HeadAimStatus::ReferenceEstablished,"map reference");
            transition.SetFloorEye(1.54f);
            f=Frame(2,.4f,-.3f,.2f); f.head.pos={1,1.60f,3};
            Check(transition.Prepare(controller,c,f,r)==HeadAimStatus::RotationRequested,"map tracked pitch");
            c=r.rotation; Check(transition.Commit(r,c),"map tracked commit");
            AppliedHeadAim before,after;
            Check(transition.RenderState(controller,c,before),"map prior state");
            const auto trackedPitch=c.pitch;
            auto newer=Frame(3,.5f,-.2f,.3f); newer.head.pos=f.head.pos;
            Check(transition.Prepare(controller,c,newer,r)==HeadAimStatus::RotationRequested,"map pending pose");
            const auto pending=r;
            const pinned::NativeRotator destination{4500,-11000,9000};
            Check(!transition.WorldUpTransition(controller+1,destination,corrected),"map controller identity");
            Check(transition.WorldUpTransition(controller,destination,corrected),"map rotation boundary");
            Check(corrected.pitch==trackedPitch && corrected.yaw==destination.yaw && corrected.roll==0,
                "map retains applied head pitch and destination camera yaw, clears authored roll");
            c=corrected;
            Check(!transition.Commit(pending,pending.rotation),"map invalidates old pending pose");
            Check(transition.RenderState(controller,c,after),"map restored render state");
            Check((after.bodyRotation.Rotate({0,0,1})-Vec3{0,0,1}).Length()<.0002f,"map body gravity stays world up");
            Check((before.reference.pos-after.reference.pos).Length()<.0002f &&
                Near(before.reference.rot.x,after.reference.rot.x) && Near(before.reference.rot.y,after.reference.rot.y) &&
                Near(before.reference.rot.z,after.reference.rot.z) && Near(before.reference.rot.w,after.reference.rot.w),
                "map retains tracking position, floor and orientation reference");
            Check(Near(transition.StandingHeight(),1.60f) && Near(transition.FloorShift(),-.06f),"map retains floor calibration");
            ++f.poseSampleId;
            Check(transition.Prepare(controller,c,f,r)==HeadAimStatus::NoChange,"stationary head after map has no repeated delta");
            newer.poseSampleId=4;
            Check(transition.Prepare(controller,c,newer,r)==HeadAimStatus::RotationRequested,"head motion resumes after map");
            c=r.rotation; Check(transition.Commit(r,c),"map subsequent commit");
            Check(transition.RenderState(controller,c,after) &&
                (after.bodyRotation.Rotate({0,0,1})-Vec3{0,0,1}).Length()<.0002f,"new head motion cannot restore map tilt");
            Check(transition.Suspend(),"map loading suspension");
            Check(transition.WorldUpTransition(controller,destination,corrected),"map repairs a suspended established reference");
            c=corrected;
            newer.poseSampleId=5;
            Check(transition.Prepare(controller,c,newer,r)==HeadAimStatus::NoChange,"map resume keeps stationary tracked history");
            Check(transition.RenderState(controller,c,after) &&
                (after.bodyRotation.Rotate({0,0,1})-Vec3{0,0,1}).Length()<.0002f,"map suspension preserves world up");
        }
        HeadAim aim;
        HeadAimRequest request;
        pinned::NativeRotator current{700,6000,300};
        Check(aim.Prepare(controller,current,Frame(1),request)==HeadAimStatus::ReferenceEstablished,"initial reference");
        Check(aim.Prepare(controller,current,Frame(2,0.4f),request)==HeadAimStatus::RotationRequested,"head yaw request");
        Check(NearUnits(request.rotation.yaw,1828),"XR left yaw maps to negative UE yaw");
        Check(request.rotation.pitch==700 && request.rotation.roll==300,"yaw preserves pitch and roll");
        current=request.rotation;
        Check(aim.Commit(request,current),"commit verified set");
        Check(!aim.Commit(request,current),"double commit rejected");
        Check(aim.Prepare(controller,current,Frame(2,0.4f),request)==HeadAimStatus::NoChange,"same sample cannot turn twice");
        current.yaw+=200; current.pitch+=40; current.roll+=15; // ordinary stock input/recoil
        Check(aim.Prepare(controller,current,Frame(3,0.4f),request)==HeadAimStatus::NoChange,"stationary head does not erase stock input");
        const auto before=current;
        Check(aim.Prepare(controller,current,Frame(4,0.45f,0.1f),request)==HeadAimStatus::RotationRequested,"incremental yaw/pitch");
        Check(NearUnits(request.rotation.yaw-before.yaw,-522),"only new yaw delta");
        Check(NearUnits(request.rotation.pitch-before.pitch,1043),"head pitch delta");
        Check(request.rotation.roll==before.roll,"stock roll preserved");
        current=request.rotation; Check(aim.Commit(request,current),"second commit");

        AppliedHeadAim applied;
        Check(aim.RenderState(controller,current,applied),"render state available");
        Check(!aim.RenderState(controller+1,current,applied),"render state controller identity");
        Check(aim.RenderState(controller,current,applied),"render state restored");
        // Current game camera includes an older gameplay head sample. A newer
        // full pose (including roll and translation) must match rendering the
        // same body camera with the head applied exactly once.
        const pinned::NativeRotator body{740,6200,315};
        // The same body basis positions both hands. Tracked head yaw/pitch
        // must never be baked into a stationary controller's world aim.
        const auto expectedHandForward=NativeActorRotation(body).Rotate({1,0,0});
        const auto handForward=applied.bodyRotation.Rotate({1,0,0});
        Check((handForward-expectedHandForward).Length()<.0002f,"hand basis excludes HMD rotation while retaining stick turn");
        const auto translation=dx::XMMatrixTranslation(100,200,300);
        const auto bodyWorld=Rotation(NativeCameraRotation(body))*translation;
        const auto aimedWorld=Rotation(NativeCameraRotation(current))*translation;
        pinned::NativeMatrix4 projection{};
        projection.m[0][0]=projection.m[1][1]=projection.m[2][2]=projection.m[2][3]=1;
        projection.m[3][2]=-10;
        auto latest=Frame(5,0.6f,0.2f,0.15f);
        latest.head.pos={0.1f,0.05f,-0.3f};
        latest.eyeLeft.pose.pos=latest.eyeLeft.pose.pos+latest.head.pos;
        latest.eyeRight.pose.pos=latest.eyeRight.pose.pos+latest.head.pos;
        std::array<EyeMatrices,2> baseline,residual;
        std::string error;
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,bodyWorld)),projection,
            applied.reference,latest,baseline,error),"unheaded baseline");
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,aimedWorld)),projection,
            applied.reference,latest,residual,error,applied.cameraRotation),"aim residual");
        for(int eye=0;eye<2;++eye) { Equal(baseline[eye].view,residual[eye].view); Equal(baseline[eye].projection,residual[eye].projection); }

        // A portal changes the engine camera's whole frame, including roll.
        // Rebase the prior applied HMD component without shifting either eye.
        HeadAim transported=aim;
        const pinned::NativeRotator exitCamera{4500,-11000,9000};
        const auto exitWorld=Rotation(NativeCameraRotation(exitCamera))*translation;
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,exitWorld)),projection,
            applied.reference,latest,baseline,error,applied.cameraRotation),"mapped portal camera baseline");
        Check(transported.RebasePortal(controller,current,latest),"portal tracking rebase");
        AppliedHeadAim exitAim;
        Check(transported.RenderState(controller,exitCamera,exitAim),"portal render reference");
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,exitWorld)),projection,
            exitAim.reference,latest,residual,error,exitAim.cameraRotation),"rebased portal eye matrices");
        for(int eye=0;eye<2;++eye) Equal(baseline[eye].view,residual[eye].view);
        auto afterPortal=latest; ++afterPortal.poseSampleId;
        Check(transported.Prepare(controller,exitCamera,afterPortal,request)==HeadAimStatus::NoChange,
            "stationary head does not repeat pre-portal rotation");

        // Failure consumes no tracked delta; a newer pose includes the missed
        // change rather than accumulating the full absolute orientation twice.
        auto newer=Frame(6,0.7f,0.2f);
        Check(aim.Prepare(controller,current,newer,request)==HeadAimStatus::RotationRequested,"uncommitted request");
        const auto stale=request;
        newer=Frame(7,0.8f,0.2f);
        Check(aim.Prepare(controller,current,newer,request)==HeadAimStatus::RotationRequested,"retry with new sample");
        Check(!aim.Commit(stale,stale.rotation),"superseded request rejected");
        Check(NearUnits(request.rotation.yaw-current.yaw,-3651),"failed update was not consumed");

        // Focus/tracking loss does not move the controller or establish a new
        // heading. Resume includes only the unconsumed tracked movement.
        newer.state=xr::SessionState::Visible;
        Check(aim.Prepare(controller,current,newer,request)==HeadAimStatus::Unavailable,"focus loss");
        Check(!aim.RenderState(controller,current,applied),"focus loss suspends render correction");
        Check(!aim.Commit(stale,stale.rotation),"pre-loss request rejected");
        Check(aim.Prepare(controller,current,Frame(8,1.5f,-0.3f),request)==HeadAimStatus::RotationRequested,"reacquire retains original reference");
        current=request.rotation;
        Check(aim.Commit(request,current),"resume commit");
        Check(aim.RenderState(controller,current,applied),"resume restores render correction");
        Check((applied.bodyRotation.Rotate({1,0,0})-expectedHandForward).Length()<.0002f,
            "focus recovery never bakes tracked pitch or yaw into the body");
        Check(aim.Prepare(controller+1,current,Frame(9,2.0f),request)==HeadAimStatus::ReferenceEstablished,"controller change rebases");
        auto invalid=Frame(10); invalid.headPoseTracked=false;
        Check(aim.Prepare(controller+1,current,invalid,request)==HeadAimStatus::Unavailable,"lost orientation tracking");
        invalid=Frame(11); invalid.head.rot={0,0,0,0};
        Check(aim.Prepare(controller+1,current,invalid,request)==HeadAimStatus::Unavailable,"invalid quaternion");

        // Reproduce the real sample-123 PNG capture hitch (>250 ms). Compare
        // interrupted tracking against an uninterrupted control with the same
        // head/stick movement, including a tilted head and room-scale lean.
        HeadAim uninterrupted, interrupted;
        pinned::NativeRotator uninterruptedRotation{0,7000,0}, interruptedRotation=uninterruptedRotation;
        auto initial=Frame(120); initial.head.pos={1,2,3};
        Check(uninterrupted.Prepare(controller,uninterruptedRotation,initial,request)==HeadAimStatus::ReferenceEstablished,"hitch control reference");
        Check(interrupted.Prepare(controller,interruptedRotation,initial,request)==HeadAimStatus::ReferenceEstablished,"hitch reference");
        auto capturePose=Frame(123,.7f,-.3f,.2f); capturePose.head.pos=initial.head.pos;
        Check(uninterrupted.Prepare(controller,uninterruptedRotation,capturePose,request)==HeadAimStatus::RotationRequested,"hitch control turn");
        uninterruptedRotation=request.rotation; Check(uninterrupted.Commit(request,uninterruptedRotation),"hitch control commit");
        Check(interrupted.Prepare(controller,interruptedRotation,capturePose,request)==HeadAimStatus::RotationRequested,"hitch turn");
        interruptedRotation=request.rotation; Check(interrupted.Commit(request,interruptedRotation),"hitch commit");
        Check(interrupted.Suspend(),"stale sample suspends reference once");
        Check(!interrupted.Suspend(),"repeated stale ticks cannot recenter");
        Check(!interrupted.RenderState(controller,interruptedRotation,applied),"no rendering from a stale pose");
        Check(interrupted.Prepare(controller,interruptedRotation,capturePose,request)==HeadAimStatus::NoChange,"same-sample recovery keeps calibration");
        Check(interrupted.RenderState(controller,interruptedRotation,applied),"same-sample recovery restores existing correction");
        interrupted.Suspend();
        uninterruptedRotation.yaw+=200; interruptedRotation.yaw+=200; // intentional player turn while suspended
        auto resumePose=Frame(124,.9f,.2f,.1f);
        resumePose.head.pos=initial.head.pos+Vec3{.2f,.1f,-.5f};
        resumePose.eyeLeft.pose.pos=resumePose.eyeLeft.pose.pos+resumePose.head.pos;
        resumePose.eyeRight.pose.pos=resumePose.eyeRight.pose.pos+resumePose.head.pos;
        // The adapter suspends input after the prior frame takes >250 ms,
        // then begins a fresh XR frame during scene submission. No controller
        // tick/Prepare occurs between that BeginFrame and the eye rendering.
        // Rendering the new pose must succeed while stale input stays closed.
        AppliedHeadAim liveRender, hitchRender;
        Check(uninterrupted.RenderState(controller,uninterruptedRotation,liveRender),"uninterrupted presentation baseline");
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,capturePose,401,hitchRender),
            "401 ms prior frame cannot supply presentation");
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,capturePose,0,hitchRender),
            "resetting age cannot reuse the last consumed sample after suspension");
        auto badRender=resumePose; badRender.poseSampleId=122;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"regressing render sample rejected");
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,resumePose,251,hitchRender),"stale new render sample rejected");
        Check(interrupted.RenderFrameState(controller,interruptedRotation,resumePose,0,hitchRender),
            "fresh current frame renders immediately after hitch without a recovery tick");
        Check(!interrupted.RenderState(controller,interruptedRotation,applied),
            "fresh presentation does not resume gameplay or hand input");
        Check(interrupted.RenderFrameState(controller,interruptedRotation,resumePose,10,hitchRender),
            "second eye may use the same fresh frame");
        const auto hitchedWorld=Rotation(NativeCameraRotation(interruptedRotation))*translation;
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,hitchedWorld)),projection,
            liveRender.reference,resumePose,baseline,error,liveRender.cameraRotation),"live current-frame stereo baseline");
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,hitchedWorld)),projection,
            hitchRender.reference,resumePose,residual,error,hitchRender.cameraRotation),"fresh stereo during gameplay suspension");
        for(int eye=0;eye<2;++eye) { Equal(baseline[eye].view,residual[eye].view); Equal(baseline[eye].projection,residual[eye].projection); }
        interrupted.ConsumeRoomMovement({50,50,0},hitchRender);
        interrupted.PivotTurn(resumePose,hitchRender,liveRender);
        Check(interrupted.RenderFrameState(controller,interruptedRotation,resumePose,20,hitchRender) &&
            (hitchRender.reference.pos-initial.head.pos).Length()<.0002f,
            "presentation recovery cannot consume room movement or change calibration");
        Check(!interrupted.RenderFrameState(controller+1,interruptedRotation,resumePose,0,hitchRender),"fresh render controller mismatch rejected");
        Check(!interrupted.RenderFrameState(0,interruptedRotation,resumePose,0,hitchRender),"missing render controller rejected");
        badRender=resumePose; ++badRender.referenceSpaceEpoch;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"fresh render cannot cross tracking epochs");
        badRender=resumePose; badRender.state=xr::SessionState::Visible;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"unfocused fresh render rejected");
        badRender=resumePose; badRender.shouldRender=false;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"runtime render refusal preserved");
        badRender=resumePose; badRender.headPoseTracked=false;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"untracked fresh render rejected");
        badRender=resumePose; badRender.headPoseValid=false;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"invalid fresh head pose rejected");
        badRender=resumePose; badRender.head.rot={0,0,0,0};
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"invalid fresh head orientation rejected");
        badRender=resumePose; badRender.viewsValid=false;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"invalid fresh eye pair rejected");
        badRender=resumePose; badRender.eyeRight.poseValid=false;
        Check(!interrupted.RenderFrameState(controller,interruptedRotation,badRender,0,hitchRender),"missing fresh eye pose rejected");
        HeadAim uncalibrated;
        Check(!uncalibrated.RenderFrameState(controller,interruptedRotation,resumePose,0,hitchRender),"presentation cannot establish calibration itself");
        // A left eye can stall after its fresh frame has already been
        // accepted. Finish that exact pair once even at 401/800 ms; do not
        // pretend its sample is fresh or admit another frame at that age.
        for (const auto stalledMilliseconds : std::array<unsigned,2>{401,800}) {
            HeadAim::RenderPairLease lease;
            AppliedHeadAim leftAim,rightAim;
            Check(interrupted.BeginRenderPair(controller,interruptedRotation,resumePose,0,lease,leftAim),
                "fresh left eye obtains presentation lease while input is suspended");
            Check(!interrupted.RenderFrameState(controller,interruptedRotation,resumePose,stalledMilliseconds,rightAim),
                "elapsed left-eye stall cannot qualify as a new fresh render");
            Check(interrupted.FinishRenderPair(controller,interruptedRotation,resumePose,lease,rightAim),
                "right eye finishes its accepted pair after a 401/800 ms left-eye stall");
            Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,hitchedWorld)),projection,
                rightAim.reference,resumePose,residual,error,rightAim.cameraRotation),"leased right eye retains stereo geometry");
            for(int eye=0;eye<2;++eye) Equal(baseline[eye].view,residual[eye].view);
            Check(!interrupted.FinishRenderPair(controller,interruptedRotation,resumePose,lease,rightAim),
                "right-eye lease is consumed exactly once");
            Check(!interrupted.RenderState(controller,interruptedRotation,applied),"finishing a stalled pair leaves gameplay input suspended");
            Check(interrupted.BeginRenderPair(controller,interruptedRotation,resumePose,0,lease,leftAim),"replacement lease begins");
            auto staleNewFrame=resumePose; ++staleNewFrame.poseSampleId;
            Check(!interrupted.BeginRenderPair(controller,interruptedRotation,staleNewFrame,stalledMilliseconds,lease,leftAim),
                "new stale frame cannot inherit the prior pair's presentation lease");
            Check(!interrupted.FinishRenderPair(controller,interruptedRotation,resumePose,lease,rightAim),
                "failed new admission clears any previous pair lease");
        }
        const auto rejectPair=[&](std::uintptr_t rightController,const pinned::NativeRotator& rightCamera,
                                  const xr::FrameState& rightFrame,const char* message) {
            HeadAim::RenderPairLease lease;
            AppliedHeadAim pairAim;
            Check(interrupted.BeginRenderPair(controller,interruptedRotation,resumePose,0,lease,pairAim),"invalid-pair fixture admitted fresh left eye");
            Check(!interrupted.FinishRenderPair(rightController,rightCamera,rightFrame,lease,pairAim),message);
            Check(!interrupted.FinishRenderPair(controller,interruptedRotation,resumePose,lease,pairAim),"rejected pair lease is also consumed");
        };
        rejectPair(controller+1,interruptedRotation,resumePose,"right eye cannot change controller");
        auto changedCamera=interruptedRotation; ++changedCamera.yaw;
        rejectPair(controller,changedCamera,resumePose,"right eye cannot change the accepted engine camera");
        badRender=resumePose; ++badRender.poseSampleId;
        rejectPair(controller,interruptedRotation,badRender,"right eye cannot use a different pose sample");
        badRender=resumePose; ++badRender.referenceSpaceEpoch;
        rejectPair(controller,interruptedRotation,badRender,"right eye cannot cross tracking epochs");
        badRender=resumePose; badRender.state=xr::SessionState::Visible;
        rejectPair(controller,interruptedRotation,badRender,"right eye still requires focus");
        badRender=resumePose; badRender.headPoseTracked=false;
        rejectPair(controller,interruptedRotation,badRender,"right eye still requires tracked head pose");
        badRender=resumePose; badRender.head.pos.x+=.01f;
        rejectPair(controller,interruptedRotation,badRender,"same sample id cannot disguise changed head geometry");
        badRender=resumePose; badRender.eyeRight.fov.angleLeft+=.01f;
        rejectPair(controller,interruptedRotation,badRender,"same sample id cannot disguise changed eye projection");
        badRender=resumePose; badRender.handLeft.grip.pos.x+=.03f;
        rejectPair(controller,interruptedRotation,badRender,"left hand cannot advance between eye renders");
        badRender=resumePose; badRender.handRight.grip.pos.z-=.03f;
        rejectPair(controller,interruptedRotation,badRender,"right hand cannot advance between eye renders");
        badRender=resumePose; badRender.handRight.aim.rot=Quat::FromAxisAngle({0,1,0},.2f);
        rejectPair(controller,interruptedRotation,badRender,"gun aim cannot advance between eye renders");
        badRender=resumePose; badRender.handLeft.poseValid=!badRender.handLeft.poseValid;
        rejectPair(controller,interruptedRotation,badRender,"hand availability cannot change between eye renders");
        {
            // Both moving hands may advance with the next XR frame. Capturing
            // that frame before placement must retain its poses for both eyes,
            // including when stock stick yaw is already in the body camera.
            auto moving=resumePose;
            moving.poseSampleId+=1;
            moving.handLeft.grip.pos={-.25f,-.2f,-.5f};
            moving.handRight.grip.pos={.35f,-.1f,-.6f};
            moving.handLeft.poseValid=moving.handRight.poseValid=true;
            moving.handLeft.aimPoseValid=moving.handRight.aimPoseValid=true;
            HeadAim::RenderPairLease lease;
            AppliedHeadAim leftAim,rightAim;
            Check(interrupted.BeginRenderPair(controller,interruptedRotation,moving,0,lease,leftAim),
                "new moving-hand frame admitted without consuming gameplay input");
            Check(interrupted.FinishRenderPair(controller,interruptedRotation,moving,lease,rightAim),
                "both eyes accept the same new moving-hand frame");
            Check((leftAim.bodyRotation.Rotate({1,0,0})-rightAim.bodyRotation.Rotate({1,0,0})).Length()<.0002f,
                "both hands retain identical body/stick yaw across eyes");
            Check(!interrupted.RenderState(controller,interruptedRotation,applied),
                "accepting hand presentation leaves suspended gameplay input closed");
        }
        HeadAim recalibrated=interrupted;
        HeadAim::RenderPairLease resetLease;
        Check(recalibrated.BeginRenderPair(controller,interruptedRotation,resumePose,0,resetLease,hitchRender),"lease before calibration reset");
        recalibrated.Reset();
        Check(recalibrated.Prepare(controller,interruptedRotation,resumePose,request)==HeadAimStatus::ReferenceEstablished,"new calibration fixture");
        Check(!recalibrated.FinishRenderPair(controller,interruptedRotation,resumePose,resetLease,hitchRender),"calibration reset invalidates outstanding pair lease");
        Check(uninterrupted.Prepare(controller,uninterruptedRotation,resumePose,request)==HeadAimStatus::RotationRequested,"uninterrupted capture recovery");
        uninterruptedRotation=request.rotation; Check(uninterrupted.Commit(request,uninterruptedRotation),"uninterrupted recovery commit");
        Check(interrupted.Prepare(controller,interruptedRotation,resumePose,request)==HeadAimStatus::RotationRequested,"hitch recovery consumes missed motion");
        interruptedRotation=request.rotation; Check(interrupted.Commit(request,interruptedRotation),"hitch recovery commit");
        Check(std::memcmp(&uninterruptedRotation,&interruptedRotation,sizeof(interruptedRotation))==0,"hitch recovery matches uninterrupted aim");
        AppliedHeadAim uninterruptedAim, interruptedAim;
        Check(uninterrupted.RenderState(controller,uninterruptedRotation,uninterruptedAim),"control render reference");
        Check(interrupted.RenderState(controller,interruptedRotation,interruptedAim),"hitch render reference");
        Check((interruptedAim.reference.pos-initial.head.pos).Length()<.0002f,"hitch does not recenter physical lean");
        Check((interruptedAim.bodyRotation.Rotate({0,0,1})-Vec3{0,0,1}).Length()<.0002f,"hitch keeps virtual gravity upright");
        const auto resumedWorld=Rotation(NativeCameraRotation(interruptedRotation))*translation;
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,resumedWorld)),projection,
            uninterruptedAim.reference,resumePose,baseline,error,uninterruptedAim.cameraRotation),"uninterrupted stereo after capture");
        Check(BuildStereoMatrices(Matrix(dx::XMMatrixInverse(nullptr,resumedWorld)),projection,
            interruptedAim.reference,resumePose,residual,error,interruptedAim.cameraRotation),"interrupted stereo after capture");
        for(int eye=0;eye<2;++eye) Equal(baseline[eye].view,residual[eye].view);
        interrupted.Reset();
        Check(interrupted.Prepare(controller,interruptedRotation,resumePose,request)==HeadAimStatus::ReferenceEstablished,"explicit respawn reset rebases even with same controller");

        // Crossing +/-pi keeps a small yaw delta, not a full turn.
        HeadAim wrap;
        current={}; wrap.Prepare(controller,current,Frame(20),request);
        Check(wrap.Prepare(controller,current,Frame(21,3.13f),request)==HeadAimStatus::RotationRequested,"near yaw boundary");
        current=request.rotation; wrap.Commit(request,current);
        Check(wrap.Prepare(controller,current,Frame(22,-3.13f),request)==HeadAimStatus::RotationRequested,"across yaw boundary");
        Check(std::abs(request.rotation.yaw-current.yaw)>65000,"native signed representation wraps");
        Check(std::abs((request.rotation.yaw-current.yaw)-65536)<300,"physical yaw change remains small");
        Check(wrap.Prepare(controller,current,Frame(1),request)==HeadAimStatus::ReferenceEstablished,"runtime sample reset rebases");
        // Collision accepts only part of a physical step. World head position
        // must remain continuous as the capsule and tracking anchor advance.
        HeadAim room;
        current={0,9000,0};
        auto standing=Frame(1000); standing.head.pos={1,1.7f,2};
        room.Prepare(controller,current,standing,request);
        auto walking=Frame(1001); walking.head.pos=standing.head.pos+Vec3{.12f,-.4f,-.2f};
        AppliedHeadAim roomBefore, roomAfter;
        room.RenderState(controller,current,roomBefore);
        const auto worldOffset=[](const AppliedHeadAim& a,const xr::FrameState& f) {
            return a.bodyRotation.Rotate(BasisXrToUnreal(a.reference.rot.Inverse().Rotate(f.head.pos-a.reference.pos)))*100.f;
        };
        const auto requested=RoomMovementRequest(roomBefore,walking,.016f);
        Check(Near(requested.Length(),4.8f,.001f) && requested.z==0,"room step bounded by real tick time and horizontal only");
        Check(Near(RoomMovementRequest(roomBefore,walking,5.f).Length(),15.f,.001f),"hitch has bounded collision budget");
        const auto oldHead=worldOffset(roomBefore,walking);
        const auto accepted=requested*.5f;
        room.ConsumeRoomMovement(accepted+Vec3{0,0,10},roomBefore);
        room.RenderState(controller,current,roomAfter);
        Check((accepted+worldOffset(roomAfter,walking)-oldHead).Length()<.002f,"consume actual swept XY only; step height remains pawn owned");
        const auto unconsumed=roomAfter.reference.pos;
        room.ConsumeRoomMovement({},roomAfter);
        room.RenderState(controller,current,roomAfter);
        Check((roomAfter.reference.pos-unconsumed).Length()<.00001f,"blocked request consumes no tracking movement");
        auto bounded=roomAfter;
        BoundRoomView(bounded,walking);
        const auto boundedOffset=worldOffset(bounded,walking);
        Check(Near(std::hypot(boundedOffset.x,boundedOffset.y),5.f,.002f),"wall cannot leave camera far outside capsule");
        Check(Near(boundedOffset.z,-40.f,.002f),"physical crouch height remains tracked");
        auto zedLean=roomAfter;
        BoundRoomView(zedLean,walking,.3f);
        const auto zedOffset=worldOffset(zedLean,walking);
        Check(std::hypot(zedOffset.x,zedOffset.y)>5.1f && std::hypot(zedOffset.x,zedOffset.y)<=30.002f,
            "a widened lean lets the head past the capsule, up to its bound");
        auto garbageLean=roomAfter;
        BoundRoomView(garbageLean,walking,std::numeric_limits<float>::quiet_NaN());
        Check((worldOffset(garbageLean,walking)-boundedOffset).Length()<.002f,"invalid lean falls back to 5 cm");
        Check(Near(SanitiseLeanMetres(0.f),.05f,.0001f) && Near(SanitiseLeanMetres(5.f),.6f,.0001f),
            "lean allowance is bounded to 5-60 cm");
        const auto headBeforeTurn=worldOffset(roomAfter,walking);
        roomBefore=roomAfter;
        current.yaw+=16384;
        room.RenderState(controller,current,roomAfter);
        room.PivotTurn(walking,roomBefore,roomAfter);
        room.RenderState(controller,current,roomAfter);
        Check((worldOffset(roomAfter,walking)-headBeforeTurn).Length()<.002f,"90 degree turn pivots at head, no orbit or vertical drift");
        BoundRoomView(roomAfter,walking);
        Check((worldOffset(roomAfter,walking)-boundedOffset).Length()<.002f,"blocked head pivot uses same bounded presentation reference");
        auto resetPose=walking; resetPose.poseSampleId=1002; resetPose.referenceSpaceEpoch=1;
        resetPose.head.pos={-3,.1f,8};
        Check(room.SpaceChanged(resetPose),"runtime origin change invalidates old space before rendering");
        current={0,current.yaw,0}; // adapter levels old camera pitch at recenter
        Check(room.Prepare(controller,current,resetPose,request)==HeadAimStatus::ReferenceEstablished,"runtime recenter establishes current eye height");
        room.RenderState(controller,current,roomAfter);
        Check(!room.SpaceChanged(resetPose) && worldOffset(roomAfter,resetPose).Length()<.001f,"recenter clears floor-height drift and room offset");
        Check(RoomMovementRequest(roomAfter,resetPose,.016f).LengthSq()==0,"origin change cannot become pawn movement");
        auto invalidRoom=resetPose; invalidRoom.headPoseTracked=false;
        Check(RoomMovementRequest(roomAfter,invalidRoom,.016f).LengthSq()==0,"lost tracking cannot move pawn");
        std::puts("Head aim checks passed: tracking, stereo, focus recovery, fresh-frame hitch presentation, swept room movement, collision residual, head pivot, recenter height");
    } catch(const std::exception& exception) {
        std::fprintf(stderr,"FAIL: %s\n",exception.what()); return 1;
    }
    return 0;
}
