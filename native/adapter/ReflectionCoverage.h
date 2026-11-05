#pragma once
#include <d3d11.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <array>
#include <cstdint>
#include <cstring>

namespace kf2vr::adapter {
// SSR's HiZ mip zero predates meshes omitted from the occlusion prepass.
// Those pixels still describe the background receiver. Remove its reflection
// when visible geometric depth has subsequently moved in front of it.
inline constexpr char kReflectionCoverageShader[] = R"(
Texture2D<float> VisibleDepth : register(t0);
Texture2D<float> ReflectionDepth : register(t1);
RWTexture2D<float4> Reflections : register(u0);
cbuffer CoverageEye : register(b0) { uint2 EyeOffset; uint2 EyeSize; };
[numthreads(16,16,1)]
void CS(uint3 id : SV_DispatchThreadID) {
    if (any(id.xy >= EyeSize)) return;
    uint2 pixel = EyeOffset + id.xy;
    float visible = VisibleDepth.Load(int3(pixel,0));
    float receiver = ReflectionDepth.Load(int3(pixel,0));
    if (receiver - visible > 2.0 / 16777215.0)
        Reflections[pixel] = float4(0,0,0,0);
}
)";

class ReflectionCoverage {
    template<class T> using Ptr=Microsoft::WRL::ComPtr<T>;
    Ptr<ID3D11Device> device_;
    Ptr<ID3D11ComputeShader> shader_;
    Ptr<ID3D11Buffer> eyeBuffer_;
    Ptr<ID3D11Texture2D> depthCopy_;
    Ptr<ID3D11ShaderResourceView> depthCopyView_;
    Ptr<ID3D11Resource> visibleDepth_;
    Ptr<ID3D11ShaderResourceView> reflectionDepth_;
    Ptr<ID3D11UnorderedAccessView> reflections_;
    std::array<std::array<std::int32_t,4>,2> eyes_{};
    UINT width_=0,height_=0;

    // Direct D3D calls must leave UE3's cached bindings true on return.
    struct Bindings {
        ID3D11DeviceContext* context;
        ID3D11RenderTargetView* targets[D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT]{};
        ID3D11DepthStencilView* depth=nullptr;
        ID3D11ComputeShader* shader=nullptr;
        ID3D11ClassInstance* instances[256]{};
        UINT instanceCount=256;
        ID3D11ShaderResourceView* inputs[2]{};
        ID3D11UnorderedAccessView* outputs[D3D11_PS_CS_UAV_REGISTER_COUNT]{};
        ID3D11ShaderResourceView* aliases[6][D3D11_COMMONSHADER_INPUT_RESOURCE_SLOT_COUNT]{};
        ID3D11Buffer* constants=nullptr;
        void GetInputs(unsigned stage,ID3D11ShaderResourceView** views) {
            constexpr UINT count=D3D11_COMMONSHADER_INPUT_RESOURCE_SLOT_COUNT;
            switch(stage) {
                case 0: context->VSGetShaderResources(0,count,views); break;
                case 1: context->HSGetShaderResources(0,count,views); break;
                case 2: context->DSGetShaderResources(0,count,views); break;
                case 3: context->GSGetShaderResources(0,count,views); break;
                case 4: context->PSGetShaderResources(0,count,views); break;
                case 5: context->CSGetShaderResources(0,count,views); break;
            }
        }
        void SetInput(unsigned stage,UINT slot,ID3D11ShaderResourceView* view) {
            switch(stage) {
                case 0: context->VSSetShaderResources(slot,1,&view); break;
                case 1: context->HSSetShaderResources(slot,1,&view); break;
                case 2: context->DSSetShaderResources(slot,1,&view); break;
                case 3: context->GSSetShaderResources(slot,1,&view); break;
                case 4: context->PSSetShaderResources(slot,1,&view); break;
                case 5: context->CSSetShaderResources(slot,1,&view); break;
            }
        }
        explicit Bindings(ID3D11DeviceContext* c,ID3D11Resource* writtenResource):context(c) {
            context->OMGetRenderTargets(D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT,targets,&depth);
            context->CSGetShader(&shader,instances,&instanceCount);
            context->CSGetShaderResources(0,2,inputs);
            context->CSGetUnorderedAccessViews(0,D3D11_PS_CS_UAV_REGISTER_COUNT,outputs);
            context->CSGetConstantBuffers(0,1,&constants);
            // The late mask may follow a pass that sampled the SSR result.
            // Explicitly remember every alias before D3D can auto-unbind it.
            for(unsigned stage=0;stage<6;++stage) {
                ID3D11ShaderResourceView* views[D3D11_COMMONSHADER_INPUT_RESOURCE_SLOT_COUNT]{};
                GetInputs(stage,views);
                for(UINT slot=0;slot<D3D11_COMMONSHADER_INPUT_RESOURCE_SLOT_COUNT;++slot) {
                    if(!views[slot]) continue;
                    Ptr<ID3D11Resource> resource; views[slot]->GetResource(&resource);
                    if(resource.Get()==writtenResource) {
                        aliases[stage][slot]=views[slot];
                        SetInput(stage,slot,nullptr);
                    } else views[slot]->Release();
                }
            }
        }
        ~Bindings() {
            ID3D11ShaderResourceView* emptyInputs[2]{};
            ID3D11UnorderedAccessView* emptyOutputs[D3D11_PS_CS_UAV_REGISTER_COUNT]{};
            context->CSSetShaderResources(0,2,emptyInputs);
            context->CSSetUnorderedAccessViews(0,D3D11_PS_CS_UAV_REGISTER_COUNT,emptyOutputs,nullptr);
            context->CSSetShader(shader,instances,instanceCount);
            context->CSSetConstantBuffers(0,1,&constants);
            context->CSSetUnorderedAccessViews(0,D3D11_PS_CS_UAV_REGISTER_COUNT,outputs,nullptr);
            context->CSSetShaderResources(0,2,inputs);
            context->OMSetRenderTargets(D3D11_SIMULTANEOUS_RENDER_TARGET_COUNT,targets,depth);
            for(unsigned stage=0;stage<6;++stage)
                for(UINT slot=0;slot<D3D11_COMMONSHADER_INPUT_RESOURCE_SLOT_COUNT;++slot)
                    if(aliases[stage][slot]) {
                        SetInput(stage,slot,aliases[stage][slot]);
                        aliases[stage][slot]->Release();
                    }
            if(shader) shader->Release();
            for(UINT i=0;i<instanceCount;++i) if(instances[i]) instances[i]->Release();
            for(auto* input:inputs) if(input) input->Release();
            for(auto* output:outputs) if(output) output->Release();
            if(constants) constants->Release();
            for(auto* target:targets) if(target) target->Release();
            if(depth) depth->Release();
        }
        Bindings(const Bindings&)=delete;
        Bindings& operator=(const Bindings&)=delete;
    };

    static bool SameDevice(ID3D11DeviceChild* child,ID3D11Device* device) {
        Ptr<ID3D11Device> actual;
        if(child) child->GetDevice(&actual);
        return actual.Get()==device;
    }
    bool Ready() {
        if(!device_) return false;
        if(!shader_) {
            Ptr<ID3DBlob> code,errors;
            if(FAILED(D3DCompile(kReflectionCoverageShader,sizeof(kReflectionCoverageShader)-1,
                    "KF2VR reflection coverage",nullptr,nullptr,"CS","cs_5_0",
                    D3DCOMPILE_OPTIMIZATION_LEVEL3,0,&code,&errors))
                || FAILED(device_->CreateComputeShader(code->GetBufferPointer(),code->GetBufferSize(),nullptr,&shader_)))
                return false;
        }
        if(!eyeBuffer_) {
            D3D11_BUFFER_DESC desc{};
            desc.ByteWidth=16; desc.Usage=D3D11_USAGE_DEFAULT;
            desc.BindFlags=D3D11_BIND_CONSTANT_BUFFER;
            if(FAILED(device_->CreateBuffer(&desc,nullptr,&eyeBuffer_))) return false;
        }
        D3D11_TEXTURE2D_DESC existing{};
        if(depthCopy_) depthCopy_->GetDesc(&existing);
        if(!depthCopy_ || existing.Width!=width_ || existing.Height!=height_) {
            depthCopyView_.Reset(); depthCopy_.Reset();
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width=width_; desc.Height=height_; desc.MipLevels=1; desc.ArraySize=1;
            desc.Format=DXGI_FORMAT_R24G8_TYPELESS; desc.SampleDesc.Count=1;
            desc.Usage=D3D11_USAGE_DEFAULT; desc.BindFlags=D3D11_BIND_SHADER_RESOURCE;
            if(FAILED(device_->CreateTexture2D(&desc,nullptr,&depthCopy_))) return false;
        }
        if(!depthCopyView_) {
            D3D11_SHADER_RESOURCE_VIEW_DESC desc{};
            desc.Format=DXGI_FORMAT_R24_UNORM_X8_TYPELESS;
            desc.ViewDimension=D3D11_SRV_DIMENSION_TEXTURE2D;
            desc.Texture2D.MipLevels=1;
            if(FAILED(device_->CreateShaderResourceView(depthCopy_.Get(),&desc,&depthCopyView_))) return false;
        }
        return true;
    }

public:
    // Copyable: the caller saves this scene's owning references when renders
    // nest, Clear()s the child scene, then restores the parent on every exit.
    void Clear() {
        visibleDepth_.Reset(); reflectionDepth_.Reset(); reflections_.Reset();
        eyes_={}; width_=height_=0;
    }
    void Reset() {
        Clear(); depthCopyView_.Reset(); depthCopy_.Reset(); eyeBuffer_.Reset();
        shader_.Reset(); device_.Reset();
    }
    bool HasCapture() const { return visibleDepth_ && reflectionDepth_ && reflections_; }

    // Call while the game's SSR t2 and u0 are still bound, after a successful
    // eye dispatch. The scene's preserved main depth is supplied explicitly:
    // compute may have no DSV bound. Incompatible input always forgets capture.
    bool Capture(ID3D11DeviceContext* context,ID3D11Resource* visibleMainDepth,
                 const std::int32_t rects[2][4]) {
        const auto previousDepth=visibleDepth_;
        const auto previousInput=reflectionDepth_;
        const auto previousOutput=reflections_;
        const auto previousEyes=eyes_;
        Clear();
        if(!context || !visibleMainDepth || !rects
            || context->GetType()!=D3D11_DEVICE_CONTEXT_IMMEDIATE) return false;
        Ptr<ID3D11Device> device; context->GetDevice(&device);
        if(device.Get()!=device_.Get()) { Reset(); device_=device; }
        Ptr<ID3D11ShaderResourceView> input;
        Ptr<ID3D11UnorderedAccessView> output;
        context->CSGetShaderResources(2,1,&input);
        context->CSGetUnorderedAccessViews(0,1,&output);
        if(!input || !output || !SameDevice(visibleMainDepth,device.Get())
            || !SameDevice(input.Get(),device.Get()) || !SameDevice(output.Get(),device.Get())) return false;
        Ptr<ID3D11Resource> inputResource,outputResource;
        input->GetResource(&inputResource); output->GetResource(&outputResource);
        if(previousDepth) {
            Ptr<ID3D11Resource> previousInputResource,previousOutputResource;
            previousInput->GetResource(&previousInputResource); previousOutput->GetResource(&previousOutputResource);
            if(previousDepth.Get()!=visibleMainDepth || previousInputResource.Get()!=inputResource.Get()
                || previousOutputResource.Get()!=outputResource.Get()
                || std::memcmp(previousEyes.data(),rects,sizeof(previousEyes))!=0) return false;
        }
        if(inputResource.Get()==visibleMainDepth || outputResource.Get()==visibleMainDepth
            || inputResource.Get()==outputResource.Get()) return false;
        Ptr<ID3D11Texture2D> depthTexture,inputTexture,outputTexture;
        if(FAILED(visibleMainDepth->QueryInterface(IID_PPV_ARGS(&depthTexture)))
            || FAILED(inputResource.As(&inputTexture)) || FAILED(outputResource.As(&outputTexture))) return false;
        D3D11_TEXTURE2D_DESC d{},i{},o{};
        depthTexture->GetDesc(&d); inputTexture->GetDesc(&i); outputTexture->GetDesc(&o);
        D3D11_SHADER_RESOURCE_VIEW_DESC s{}; input->GetDesc(&s);
        D3D11_UNORDERED_ACCESS_VIEW_DESC u{}; output->GetDesc(&u);
        if((d.Format!=DXGI_FORMAT_R24G8_TYPELESS && d.Format!=DXGI_FORMAT_D24_UNORM_S8_UINT)
            || d.MipLevels!=1 || d.ArraySize!=1 || d.SampleDesc.Count!=1 || d.SampleDesc.Quality!=0
            || !(d.BindFlags&D3D11_BIND_DEPTH_STENCIL)
            || !d.Width || !d.Height || d.Width>8192 || d.Height>8192
            || i.Width!=d.Width || i.Height!=d.Height || i.ArraySize!=1 || i.SampleDesc.Count!=1
            || (i.Format!=DXGI_FORMAT_R32_FLOAT && i.Format!=DXGI_FORMAT_R32_TYPELESS)
            || s.Format!=DXGI_FORMAT_R32_FLOAT || s.ViewDimension!=D3D11_SRV_DIMENSION_TEXTURE2D
            || s.Texture2D.MostDetailedMip!=0 || s.Texture2D.MipLevels==0
            || o.Width!=d.Width || o.Height!=d.Height || o.ArraySize!=1 || o.SampleDesc.Count!=1
            || (u.Format!=DXGI_FORMAT_R10G10B10A2_UNORM && u.Format!=DXGI_FORMAT_R16G16B16A16_FLOAT
                && u.Format!=DXGI_FORMAT_R32G32B32A32_FLOAT)
            || u.ViewDimension!=D3D11_UAV_DIMENSION_TEXTURE2D || u.Texture2D.MipSlice!=0) return false;
        for(unsigned eye=0;eye<2;++eye) {
            const auto* r=rects[eye];
            if(r[0]<0 || r[1]<0 || r[2]<1 || r[3]<1
                || std::uint32_t(r[0])>=d.Width || std::uint32_t(r[1])>=d.Height
                || std::uint32_t(r[2])>d.Width-std::uint32_t(r[0])
                || std::uint32_t(r[3])>d.Height-std::uint32_t(r[1])) return false;
        }
        const auto* a=rects[0]; const auto* b=rects[1];
        if(!(a[0]>=b[0]+b[2] || b[0]>=a[0]+a[2] || a[1]>=b[1]+b[3] || b[1]>=a[1]+a[3])) return false;
        visibleDepth_=visibleMainDepth; reflectionDepth_=input; reflections_=output;
        std::memcpy(eyes_.data(),rects,sizeof(eyes_));
        width_=d.Width; height_=d.Height;
        return true;
    }

    // Repeat after foreground basepass if needed. The mask is idempotent and
    // compares against this scene's original HiZ receiver depth each time.
    bool Mask(ID3D11DeviceContext* context) {
        if(!HasCapture() || !context || context->GetType()!=D3D11_DEVICE_CONTEXT_IMMEDIATE
            || !SameDevice(context,device_.Get())) { Clear(); return false; }
        if(!Ready()) { Clear(); return false; }
        // OMSetRenderTargets can disturb pixel UAV bindings. These scene
        // boundaries normally have none; reject another pass instead of
        // guessing its RTV/UAV slot partition or upsetting UE3's state cache.
        ID3D11UnorderedAccessView* pixelOutputs[D3D11_PS_CS_UAV_REGISTER_COUNT]{};
        context->OMGetRenderTargetsAndUnorderedAccessViews(0,nullptr,nullptr,0,
            D3D11_PS_CS_UAV_REGISTER_COUNT,pixelOutputs);
        bool pixelUavBound=false;
        for(auto* output:pixelOutputs) if(output) { pixelUavBound=true; output->Release(); }
        if(pixelUavBound) { Clear(); return false; }
        Ptr<ID3D11Resource> outputResource; reflections_->GetResource(&outputResource);
        Bindings restore(context,outputResource.Get());
        context->OMSetRenderTargets(0,nullptr,nullptr);
        context->CopyResource(depthCopy_.Get(),visibleDepth_.Get());
        ID3D11UnorderedAccessView* emptyOutputs[D3D11_PS_CS_UAV_REGISTER_COUNT]{};
        context->CSSetUnorderedAccessViews(0,D3D11_PS_CS_UAV_REGISTER_COUNT,emptyOutputs,nullptr);
        ID3D11ShaderResourceView* inputs[]{depthCopyView_.Get(),reflectionDepth_.Get()};
        ID3D11UnorderedAccessView* output=reflections_.Get();
        ID3D11Buffer* constants=eyeBuffer_.Get();
        context->CSSetShader(shader_.Get(),nullptr,0);
        context->CSSetShaderResources(0,2,inputs);
        context->CSSetUnorderedAccessViews(0,1,&output,nullptr);
        context->CSSetConstantBuffers(0,1,&constants);
        for(const auto& eye:eyes_) {
            context->UpdateSubresource(eyeBuffer_.Get(),0,nullptr,eye.data(),0,0);
            context->Dispatch((UINT(eye[2])+15)/16,(UINT(eye[3])+15)/16,1);
        }
        return true;
    }
};
}
