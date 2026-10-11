#pragma once
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <cstring>
#include <cmath>
#include <cstdint>

namespace kf2vr::adapter {
// KF2's screen-space reflections compute shader ("ScreenSpaceReflections [CS]",
// KFGame.exe 0x3605d0) assumes one view covering the whole scene buffer: pixel
// UV = thread / BufferSize, the trace runs in [0,1] of the buffer and the end
// point is projected to the whole buffer. In a single-pass two-eye buffer that
// traced both eyes as one wide image with the left eye's camera.
//
// This is the same shader, translated from the game's bytecode, with an eye
// rectangle: the pixel and trace run in the eye's own UV, every texture access
// and the output hit UV map into the buffer, and the hierarchical depth cells
// follow the buffer's mip grid. With EyeOffset 0 and EyeSize = BufferSize it is
// the game's shader. The game's bindings are reused (t0-t2, s0-s2, u0, b8, b10);
// the eye rectangle is b11.
inline constexpr char kStereoReflectionsShader[] = R"(
cbuffer CSOffsetConstants : register(b8) { float4 C8[14]; };
cbuffer SSRConstants : register(b10) { float4 C10[2]; };
cbuffer StereoEye : register(b11) { float2 EyeOffset; float2 EyeSize; };
Texture2D WorldNormalGBufferTexture : register(t0);
Texture2D SpecularGBufferTexture : register(t1);
Texture2D DepthBufferTexture : register(t2);
SamplerState WorldNormalGBufferTextureSampler : register(s0);
SamplerState SpecularGBufferTextureSampler : register(s1);
SamplerState DepthBufferTextureSampler : register(s2);
RWTexture2D<float4> ReflectionTexOut : register(u0);

[numthreads(32,32,1)]
void CS(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= (uint2)EyeSize)) return;
    const uint2 pixel = id.xy + (uint2)EyeOffset;
    const float2 bufferSize = C10[0].xy;
    const float2 scale = EyeSize / bufferSize, bias = EyeOffset / bufferSize;
    ReflectionTexOut[pixel] = float4(0,0,0,0);
    float4 normal = WorldNormalGBufferTexture.Load(int3(pixel,0)) * float4(2,2,2,1) + float4(-1,-1,-1,0);
    if ((int(normal.w * 3.0) & 2) == 0) return;
    const float2 uv = float2(id.xy) / EyeSize;
    const float2 clip = uv * float2(2,-2) + float2(-1,1);
    const float3 ray = C8[11].xyz * clip.x + C8[12].xyz * clip.y + C8[13].xyz;
    const float3 view = ray * rsqrt(dot(ray,ray));
    const float3 reflected = normal.xyz * -(2.0 * dot(view,normal.xyz)) + view;
    float facing = saturate((dot(-view,reflected) - 0.25) * 4.0);
    facing = 1.0 - (3.0 - 2.0 * facing) * (facing * facing);
    float4 result = float4(0,0,0,0);
    if (0.0 < facing) {
        const float depth = DepthBufferTexture.Load(int3(pixel,0)).x;
        const float sceneDepth = 1.0 / (min(depth,0.999) * C8[0].z - C8[0].w);
        const float3 end = reflected * 10.0 + sceneDepth * ray;
        const float4 projected = C8[7] * end.x + C8[8] * end.y + C8[9] * end.z + C8[10];
        const float3 endUv = (projected.xyz / projected.w) * float3(0.5,-0.5,1) + float3(0.5,0.5,0);
        const float3 start = float3(uv,depth);
        const float3 dir = normalize(endUv - start);
        float3 position = dir * 0.000001 + start;
        const int lastMip = asint(C10[1].x) - 1;
        const int2 cells = int2(bufferSize);
        const bool2 forward = 0.0 < dir.xy;
        int mip = 0;
        [loop] for (int step = 0; mip > -1 && mip < lastMip && step < 20; ++step) {
            const float2 size = float2(cells >> mip);
            const float2 bufferCells = size * (position.xy * scale + bias);
            const float2 edge = (forward ? ceil(bufferCells) / size : floor(bufferCells) / size) - bias;
            const float2 to = (edge / scale - position.xy) / dir.xy;
            const float t = (abs(to.x) < abs(to.y) ? to.x : to.y) + 0.05;
            position = t * dir + position;
            if (!(position.x >= 0.0 && position.y >= 0.0 && !(position.x >= 1.0) && !(position.y >= 1.0))) break;
            const float scene = DepthBufferTexture.SampleLevel(DepthBufferTextureSampler, position.xy * scale + bias, (float)mip).x;
            if (position.z < scene) ++mip;
            else { position = position - dir * ((position.z - scene) / dir.z); --mip; }
        }
        if (mip == -1) {
            float2 specular = SpecularGBufferTexture.SampleLevel(SpecularGBufferTextureSampler, uv * scale + bias, 0).xw;
            specular.y += specular.y < 0.501961 ? -0.0 : -0.501961;
            specular *= float2(0.5,2.007874);
            result.w = max(specular.y * specular.y * -300.0 + 31.0, 1.0);
            const float3 hit = WorldNormalGBufferTexture.SampleLevel(WorldNormalGBufferTextureSampler, position.xy * scale + bias, 0).xyz;
            float back = saturate((dot(hit * 2.0 - 1.0, -reflected) + 0.17) * 5.882353);
            back = back * back * (back * -2.0 + 3.0);
            const float valid = hit.y * hit.x >= 0.0001 ? 1.0 : 0.0;
            float travel = saturate((length(position.xy - uv) * 4.0 - 0.5) * 2.0);
            travel = 1.0 - (travel * -2.0 + 3.0) * (travel * travel);
            float4 border = saturate((position.xyxy + float4(-0.05,-0.05,-0.95,-0.95)) * float4(20,20,19.999996,19.999996));
            const float4 curve = border * -2.0 + 3.0;
            border *= border;
            const float2 fade = border.xy * curve.xy * (1.0 - curve.zw * border.zw);
            result.z = valid * (fade.y * fade.x * (facing * (travel * (back * (specular.x)))));
            result.xy = position.xy * scale + bias;
        }
    }
    ReflectionTexOut[pixel] = result;
}
)";

class StereoReflections {
    Microsoft::WRL::ComPtr<ID3D11ComputeShader> shader_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> eye_;
    Microsoft::WRL::ComPtr<ID3D11Device> device_;
    bool failed_=false;
public:
    static bool ValidPair(const std::int32_t rects[2][4]) {
        for(unsigned i=0;i<2;++i) {
            const auto* r=rects[i];
            if(r[0]<0 || r[1]<0 || r[2]<1 || r[3]<1 || r[0]>8192 || r[1]>8192
                || r[2]>8192-r[0] || r[3]>8192-r[1]) return false;
        }
        const auto* a=rects[0]; const auto* b=rects[1];
        return a[0]>=b[0]+b[2] || b[0]>=a[0]+a[2] || a[1]>=b[1]+b[3] || b[1]>=a[1]+a[3];
    }
    void Reset() { shader_.Reset(); eye_.Reset(); device_.Reset(); failed_=false; }
    bool Ready(ID3D11Device* device) {
        if (device!=device_.Get()) { Reset(); device_=device; }
        if (shader_ || failed_ || !device) return shader_!=nullptr;
        Microsoft::WRL::ComPtr<ID3DBlob> code,errors;
        D3D11_BUFFER_DESC b{}; b.ByteWidth=16; b.Usage=D3D11_USAGE_DEFAULT; b.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
        failed_=FAILED(D3DCompile(kStereoReflectionsShader,sizeof(kStereoReflectionsShader)-1,"KF2VR stereo reflections",
                nullptr,nullptr,"CS","cs_5_0",D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors))
            || FAILED(device->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&shader_))
            || FAILED(device->CreateBuffer(&b,nullptr,&eye_));
        if (failed_) { shader_.Reset(); eye_.Reset(); }
        return shader_!=nullptr;
    }
    bool Failed() const { return failed_; }
    // Replaces the game's bound SSR shader for one dispatch over the eye
    // rectangle (pixels in the scene buffer); the game's shader and b11 return.
    bool Dispatch(ID3D11DeviceContext* context,const float eye[4],
                  void (STDMETHODCALLTYPE* dispatch)(ID3D11DeviceContext*,UINT,UINT,UINT)) {
        if (!context || !shader_ || !dispatch || context->GetType()!=D3D11_DEVICE_CONTEXT_IMMEDIATE) return false;
        Microsoft::WRL::ComPtr<ID3D11Device> contextDevice; context->GetDevice(&contextDevice);
        if(contextDevice.Get()!=device_.Get()) return false;
        for(unsigned i=0;i<4;++i) if(!std::isfinite(eye[i]) || eye[i]!=std::floor(eye[i])) return false;
        if(eye[0]<0 || eye[1]<0 || eye[2]<1 || eye[3]<1 || eye[0]+eye[2]>8192 || eye[1]+eye[3]>8192) return false;
        Microsoft::WRL::ComPtr<ID3D11UnorderedAccessView> output; context->CSGetUnorderedAccessViews(0,1,&output);
        Microsoft::WRL::ComPtr<ID3D11Resource> resource; if(output) output->GetResource(&resource);
        Microsoft::WRL::ComPtr<ID3D11Texture2D> target;
        D3D11_TEXTURE2D_DESC d{}; if(!resource || FAILED(resource.As(&target))) return false;
        target->GetDesc(&d);
        D3D11_UNORDERED_ACCESS_VIEW_DESC u{}; output->GetDesc(&u);
        if(d.Width>8192 || d.Height>8192 || d.ArraySize!=1 || d.SampleDesc.Count!=1
            || u.ViewDimension!=D3D11_UAV_DIMENSION_TEXTURE2D || u.Texture2D.MipSlice!=0
            || eye[0]+eye[2]>float(d.Width) || eye[1]+eye[3]>float(d.Height)) return false;
        ID3D11ComputeShader* gameShader=nullptr; ID3D11ClassInstance* instances[256]{}; UINT instanceCount=256;
        context->CSGetShader(&gameShader,instances,&instanceCount);
        ID3D11Buffer* gameEye=nullptr; context->CSGetConstantBuffers(11,1,&gameEye);
        context->UpdateSubresource(eye_.Get(),0,nullptr,eye,0,0);
        context->CSSetShader(shader_.Get(),nullptr,0);
        ID3D11Buffer* mine=eye_.Get(); context->CSSetConstantBuffers(11,1,&mine);
        dispatch(context,(static_cast<UINT>(eye[2])+31)/32,(static_cast<UINT>(eye[3])+31)/32,1);
        context->CSSetConstantBuffers(11,1,&gameEye);
        context->CSSetShader(gameShader,instances,instanceCount);
        if (gameEye) gameEye->Release();
        if (gameShader) gameShader->Release();
        for (UINT i=0;i<instanceCount;++i) if (instances[i]) instances[i]->Release();
        return true;
    }
};
}
