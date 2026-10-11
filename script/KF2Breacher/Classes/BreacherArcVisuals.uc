// Optional package presentation helpers. Reuses our shipped Breacher textures
// without importing KF2VR script classes or modifying any shared material.
class BreacherArcVisuals extends Object abstract;

static function MaterialInstanceConstant Surface(Object OuterObject,string Prefix)
{
    local MaterialInstanceConstant M;
    local Texture2D D,N,S;
    D=Texture2D(DynamicLoadObject("KF2VRHands."$Prefix$"_D",class'Texture2D',true));
    N=Texture2D(DynamicLoadObject("KF2VRHands."$Prefix$"_N",class'Texture2D',true));
    S=Texture2D(DynamicLoadObject("KF2VRHands."$Prefix$"_S",class'Texture2D',true));
    if (D==None || N==None || S==None) return None;
    M=new(OuterObject) class'MaterialInstanceConstant';
    M.SetParent(MaterialInstanceConstant'CHR_1P_Arms_MAT.CHR_Master_1stP_Arms_MIC');
    M.SetTextureParameterValue('Tex2d_Diff',D);
    M.SetTextureParameterValue('Tex2d_Norm',N);
    M.SetTextureParameterValue('Tex2d_Spec',S);
    M.SetTextureParameterValue('Tex2d_SSSMask',Texture2D'EngineResources.Black');
    M.SetScalarParameterValue('scalar_reflectionIntensity',0.2);
    M.SetScalarParameterValue('Scalar_SpecPower',24);
    return M;
}

static function StaticMeshComponent Part(Actor A,StaticMesh Mesh)
{
    local StaticMeshComponent C;
    if (A==None || Mesh==None) return None;
    C=new(A) class'StaticMeshComponent';
    C.SetStaticMesh(Mesh);
    C.SetActorCollision(false,false,false);
    C.SetTraceBlocking(false,false);
    C.SetBlockRigidBody(false);
    C.CastShadow=false;
    C.SetDepthPriorityGroup(SDPG_World);
    A.AttachComponent(C);
    return C;
}
