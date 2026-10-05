// Actual compiled UnrealScript math, runnable in game or by a commandlet.
class VRPortalMathChecks extends Object;

var int Checks, Failures;

function Check(name CaseName, bool bPassed)
{
    ++Checks;
    if (!bPassed) ++Failures;
    `log("KF2VR_PORTAL_MATH case=" $ CaseName @ "passed=" $ bPassed);
}

function int Run()
{
    local vector V, W, P, Q, X,Y,Z, CrossPoint, EyeA, EyeB;
    local rotator A, B, R;
    local int I,J;
    local float MaxSpeedError, MaxRoundTripError, MaxBasisError;
    V=vect(-500,70,-980);
    W=class'VRPortalMath'.static.MapVector(V,rot(0,0,0),rot(0,0,0));
    Check('inward_maps_outward',VSize(W-vect(500,-70,-980))<0.001);
    W=class'VRPortalMath'.static.MapVector(vect(0,0,-1200),rot(16384,0,0),rot(0,0,0));
    Check('floor_to_wall_fling',VSize(W-vect(1200,0,0))<0.01);
    W=class'VRPortalMath'.static.MapVector(vect(-1200,0,0),rot(0,0,0),rot(-16384,0,0));
    Check('wall_to_ceiling',VSize(W-vect(0,0,-1200))<0.01);
    P=vect(200,60,90);
    Q=class'VRPortalMath'.static.MapPoint(P,vect(100,20,30),rot(0,0,0),vect(1000,500,300),rot(0,0,0));
    Check('position_preserves_lateral_offset',VSize(Q-vect(900,460,360))<0.001);
    for (I=0; I<12; ++I)
        for (J=0; J<12; ++J)
        {
            A.Pitch=I*4321; A.Yaw=I*719; A.Roll=I*307;
            B.Pitch=J*1811; B.Yaw=J*7717; B.Roll=J*1301;
            W=class'VRPortalMath'.static.MapVector(V,A,B);
            MaxSpeedError=FMax(MaxSpeedError,Abs(VSize(W)-VSize(V)));
            Q=class'VRPortalMath'.static.MapVector(W,B,A);
            MaxRoundTripError=FMax(MaxRoundTripError,VSize(Q-V));
            R=class'VRPortalMath'.static.MapRotation(rot(3911,7291,823),A,B);
            GetAxes(R,X,Y,Z);
            MaxBasisError=FMax(MaxBasisError,Abs(X dot Y)+Abs(X dot Z)+Abs(Y dot Z));
        }
    Check('speed_preserved_144_frames',MaxSpeedError<0.01);
    Check('roundtrip_144_frames',MaxRoundTripError<0.01);
    Check('rotation_orthonormal_144_frames',MaxBasisError<0.001);
    Check('aperture_center',class'VRPortalMath'.static.InsideEllipse(vect(0,0,0),80,140,34,86));
    Check('aperture_diagonal_rejected',!class'VRPortalMath'.static.InsideEllipse(vect(0,45,90),80,140,20,40));
    Check('oversize_rejected',!class'VRPortalMath'.static.InsideEllipse(vect(0,0,0),80,140,81,1));
    Check('degenerate_rejected',!class'VRPortalMath'.static.InsideEllipse(vect(0,0,0),0,140));
    Check('negative_radius_rejected',!class'VRPortalMath'.static.InsideEllipse(vect(0,0,0),80,140,-1,1));
    Check('front_to_back_crossing',class'VRPortalMath'.static.SweptCrossing(vect(100,30,40),vect(-100,50,60),
        vect(0,0,0),rot(0,0,0),0,CrossPoint) && VSize(CrossPoint-vect(0,40,50))<0.001);
    Check('backface_rejected',!class'VRPortalMath'.static.SweptCrossing(vect(-100,0,0),vect(100,0,0),
        vect(0,0,0),rot(0,0,0),0,CrossPoint));
    Check('parallel_rejected',!class'VRPortalMath'.static.SweptCrossing(vect(50,0,0),vect(50,500,0),
        vect(0,0,0),rot(0,0,0),0,CrossPoint));
    Check('no_crossing_rejected',!class'VRPortalMath'.static.SweptCrossing(vect(100,0,0),vect(50,0,0),
        vect(0,0,0),rot(0,0,0),0,CrossPoint));
    Check('leading_hull_plane',class'VRPortalMath'.static.SweptCrossing(vect(100,0,0),vect(20,0,0),
        vect(0,0,0),rot(0,0,0),36,CrossPoint) && Abs(CrossPoint.X-36)<0.001);
    A=class'VRPortalMath'.static.MakeBasis(vect(1,0,0),vect(-1,0,0));
    GetAxes(A,X,Y,Z);
    Check('wall_basis_upright',VSize(X-vect(1,0,0))<0.001 && VSize(Z-vect(0,0,1))<0.001);
    A=class'VRPortalMath'.static.MakeBasis(vect(0,0,1),vect(0,0,-1));
    GetAxes(A,X,Y,Z);
    Check('vertical_shot_basis_nondegenerate',VSize(X-vect(0,0,1))<0.001
        && Abs(VSize(Y)-1)<0.001 && Abs(VSize(Z)-1)<0.001);
    EyeA=class'VRPortalMath'.static.MapPoint(vect(100,-3.2,0),vect(0,0,0),rot(0,0,0),vect(1000,0,0),rot(0,16384,0));
    EyeB=class'VRPortalMath'.static.MapPoint(vect(100,3.2,0),vect(0,0,0),rot(0,0,0),vect(1000,0,0),rot(0,16384,0));
    Check('eye_separation_preserved_math_only',Abs(VSize(EyeA-EyeB)-6.4)<0.001);
    `log("KF2VR_PORTAL_MATH complete checks=" $ Checks @ "failures=" $ Failures
        @ "speedError=" $ MaxSpeedError @ "roundtripError=" $ MaxRoundTripError);
    return Failures == 0 ? 0 : 1;
}
