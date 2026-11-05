// Tight held-part capsules against the actual Gorefast blade triangles.
// Both meshes move over the same interval; a still gun can meet a moving blade.
class VRWeaponBlockGeometry extends Object;

struct BlockCapsule
{
    var vector A, B;
    var float Radius;
};
struct BladeTriangle
{
    var vector A, B, C;
};
var array<BladeTriangle> Blade;

static function vector ClosestSegment(vector A, vector B, vector P)
{
    local vector D;
    D = B - A;
    return A + D * FClamp(((P-A) dot D) / FMax(VSizeSq(D), 0.00001), 0, 1);
}

static function float Segments(vector A, vector B, vector C, vector D, out vector At)
{
    local vector U, V, W, P, Q;
    local float AA, BB, CC, DD, EE, Den, S, T;
    U=B-A; V=D-C; W=A-C;
    AA=U dot U; BB=U dot V; CC=V dot V; DD=U dot W; EE=V dot W;
    Den=AA*CC-BB*BB;
    S=(Den>0.00001) ? FClamp((BB*EE-CC*DD)/Den,0,1) : 0.0;
    T=(CC>0.00001) ? (BB*S+EE)/CC : 0.0;
    if(T<0) { T=0; S=FClamp(-DD/FMax(AA,0.00001),0,1); }
    else if(T>1) { T=1; S=FClamp((BB-DD)/FMax(AA,0.00001),0,1); }
    P=A+U*S; Q=C+V*T; At=(P+Q)*0.5;
    return VSizeSq(P-Q);
}

static function bool InTriangle(vector P, vector A, vector B, vector C, vector N)
{
    return (((B-A) cross (P-A)) dot N)>=-0.0001
        && (((C-B) cross (P-B)) dot N)>=-0.0001
        && (((A-C) cross (P-C)) dot N)>=-0.0001;
}

static function float SegmentTriangle(vector P, vector Q, vector A, vector B, vector C, out vector At)
{
    local vector N, Projected, Candidate;
    local float DP, DQ, Best, Dist;
    N=Normal((B-A) cross (C-A));
    DP=(P-A) dot N; DQ=(Q-A) dot N;
    if(DP*DQ<=0 && Abs(DP-DQ)>0.00001)
    {
        Projected=P+(Q-P)*(DP/(DP-DQ));
        if(InTriangle(Projected,A,B,C,N)) { At=Projected; return 0; }
    }
    Best=Segments(P,Q,A,B,At);
    Dist=Segments(P,Q,B,C,Candidate); if(Dist<Best) { Best=Dist; At=Candidate; }
    Dist=Segments(P,Q,C,A,Candidate); if(Dist<Best) { Best=Dist; At=Candidate; }
    Projected=P-N*DP;
    if(DP*DP<Best && InTriangle(Projected,A,B,C,N)) { Best=DP*DP; At=Projected; }
    Projected=Q-N*DQ;
    if(DQ*DQ<Best && InTriangle(Projected,A,B,C,N)) { Best=DQ*DQ; At=Projected; }
    return Best;
}

// Adaptive subdivision bounds untested relative travel to half a unit. Hitches
// and teleports reseed instead of manufacturing a contact through the world.
static function bool Sweep(BlockCapsule Shape, vector OldRoot, quat OldQ, vector Root, quat Q,
    vector OldBlade, quat OldBladeQ, vector BladeRoot, quat BladeQ, float BladeScale,
    out vector Contact, out vector NormalOut)
{
    local vector A0,B0,A,B,V0,V1,V2,N,BroadA,BroadB,Unused,At,BladeAt;
    local quat SampleQ,SampleBladeQ;
    local float Travel,T,Best;
    local int I,J,Steps;
    A0=OldRoot+QuatRotateVector(OldQ,Shape.A); B0=OldRoot+QuatRotateVector(OldQ,Shape.B);
    Travel=VSize((Root-OldRoot)-(BladeRoot-OldBlade))
        +2*ACos(FClamp(Abs(Q.X*OldQ.X+Q.Y*OldQ.Y+Q.Z*OldQ.Z+Q.W*OldQ.W),0,1))
            *FMax(VSize(Shape.A),VSize(Shape.B))
        +2*ACos(FClamp(Abs(BladeQ.X*OldBladeQ.X+BladeQ.Y*OldBladeQ.Y+BladeQ.Z*OldBladeQ.Z+BladeQ.W*OldBladeQ.W),0,1))
            *123*BladeScale;
    if(Travel>128) return false;
    // Broad phase only: the generous forearm-local capsule rejects separated
    // solids cheaply; every accepted contact still uses the thin triangles.
    BroadA=OldBlade+QuatRotateVector(OldBladeQ,vect(-25,-2,-5)*BladeScale);
    BroadB=OldBlade+QuatRotateVector(OldBladeQ,vect(-121,-2,-5)*BladeScale);
    if(Segments(A0,B0,BroadA,BroadB,Unused)>Square(Shape.Radius+15*BladeScale+Travel)) return false;
    Steps=Clamp(int(Travel/0.5)+1,1,256);
    for(J=0;J<=Steps;++J)
    {
        T=float(J)/float(Steps);
        At=VLerp(OldRoot,Root,T); BladeAt=VLerp(OldBlade,BladeRoot,T);
        SampleQ=QuatSlerp(OldQ,Q,T,true); SampleBladeQ=QuatSlerp(OldBladeQ,BladeQ,T,true);
        A=At+QuatRotateVector(SampleQ,Shape.A); B=At+QuatRotateVector(SampleQ,Shape.B);
        for(I=0;I<default.Blade.Length;++I)
        {
            V0=BladeAt+QuatRotateVector(SampleBladeQ,default.Blade[I].A*BladeScale);
            V1=BladeAt+QuatRotateVector(SampleBladeQ,default.Blade[I].B*BladeScale);
            V2=BladeAt+QuatRotateVector(SampleBladeQ,default.Blade[I].C*BladeScale);
            Best=SegmentTriangle(A,B,V0,V1,V2,Contact);
            if(Best>Square(Shape.Radius+0.25)) continue;
            N=Normal((V1-V0) cross (V2-V0));
            if(((A+B)*0.5-Contact) dot N < 0) N=-N;
            NormalOut=N;
            return true;
        }
    }
    return false;
}

defaultproperties
{
    Blade(0)=(A=(X=-118.393774,Y=-4.710864,Z=-14.309102),B=(X=-120.876661,Y=0.653965,Z=-0.177611),C=(X=-118.369597,Y=-3.462444,Z=-14.659624))
    Blade(1)=(A=(X=-120.876661,Y=0.653965,Z=-0.177611),B=(X=-118.393774,Y=-4.710864,Z=-14.309102),C=(X=-120.899993,Y=-0.593856,Z=0.173540))
    Blade(2)=(A=(X=-120.815091,Y=0.730207,Z=2.494610),B=(X=-120.876661,Y=0.653965,Z=-0.177611),C=(X=-120.899993,Y=-0.593856,Z=0.173540))
    Blade(3)=(A=(X=-118.369597,Y=-3.462444,Z=-14.659624),B=(X=-116.250067,Y=-2.115371,Z=-4.924619),C=(X=-118.393774,Y=-4.710864,Z=-14.309102))
    Blade(4)=(A=(X=-116.250067,Y=-2.115371,Z=-4.924619),B=(X=-118.369597,Y=-3.462444,Z=-14.659624),C=(X=-116.226765,Y=-0.867582,Z=-5.275895))
    Blade(5)=(A=(X=-118.369597,Y=-3.462444,Z=-14.659624),B=(X=-120.876661,Y=0.653965,Z=-0.177611),C=(X=-116.226765,Y=-0.867582,Z=-5.275895))
    Blade(6)=(A=(X=-25.162423,Y=-0.734399,Z=0.530316),B=(X=-116.226765,Y=-0.867582,Z=-5.275895),C=(X=-120.876661,Y=0.653965,Z=-0.177611))
    Blade(7)=(A=(X=-120.876661,Y=0.653965,Z=-0.177611),B=(X=-25.101433,Y=-0.658541,Z=3.201780),C=(X=-25.162423,Y=-0.734399,Z=0.530316))
    Blade(8)=(A=(X=-25.101433,Y=-0.658541,Z=3.201780),B=(X=-120.876661,Y=0.653965,Z=-0.177611),C=(X=-120.815091,Y=0.730207,Z=2.494610))
    Blade(9)=(A=(X=-116.226765,Y=-0.867582,Z=-5.275895),B=(X=-25.162423,Y=-0.734399,Z=0.530316),C=(X=-25.307932,Y=-2.134062,Z=-4.462528))
    Blade(10)=(A=(X=-118.393774,Y=-4.710864,Z=-14.309102),B=(X=-116.250067,Y=-2.115371,Z=-4.924619),C=(X=-120.899993,Y=-0.593856,Z=0.173540))
    Blade(11)=(A=(X=-25.101433,Y=-0.658541,Z=3.201780),B=(X=-25.186149,Y=-1.982548,Z=0.880465),C=(X=-25.162423,Y=-0.734399,Z=0.530316))
    Blade(12)=(A=(X=-120.815091,Y=0.730207,Z=2.494610),B=(X=-25.186149,Y=-1.982548,Z=0.880465),C=(X=-25.101433,Y=-0.658541,Z=3.201780))
    Blade(13)=(A=(X=-25.186149,Y=-1.982548,Z=0.880465),B=(X=-120.815091,Y=0.730207,Z=2.494610),C=(X=-120.899993,Y=-0.593856,Z=0.173540))
    Blade(14)=(A=(X=-116.250067,Y=-2.115371,Z=-4.924619),B=(X=-25.186149,Y=-1.982548,Z=0.880465),C=(X=-120.899993,Y=-0.593856,Z=0.173540))
    Blade(15)=(A=(X=-25.186149,Y=-1.982548,Z=0.880465),B=(X=-116.250067,Y=-2.115371,Z=-4.924619),C=(X=-25.331621,Y=-3.382310,Z=-4.112353))
    Blade(16)=(A=(X=-116.250067,Y=-2.115371,Z=-4.924619),B=(X=-25.307932,Y=-2.134062,Z=-4.462528),C=(X=-25.331621,Y=-3.382310,Z=-4.112353))
    Blade(17)=(A=(X=-25.307932,Y=-2.134062,Z=-4.462528),B=(X=-116.250067,Y=-2.115371,Z=-4.924619),C=(X=-116.226765,Y=-0.867582,Z=-5.275895))
}
