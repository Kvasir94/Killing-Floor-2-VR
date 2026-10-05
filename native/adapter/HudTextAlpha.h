#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <array>
#include <utility>
#include <vector>

namespace kf2vr::adapter {
// Canvas text deliberately writes RGB only for the stock screen HUD. A world
// panel also needs glyph coverage in alpha. Register only a transparent target
// cleared immediately before an owned HUD/hand-selector RenderDisplay callback.
class HudTextAlpha {
public:
    static constexpr unsigned PanelCount=12,SelectorCount=2;
    // Status, left/right weapon readout, session module, alert banner, the
    // ammo pouch counter and six teammate tags.
    static constexpr unsigned PanelWidth[PanelCount]{1024,800,800,1024,1024,800,512,512,512,512,512,512};
    static constexpr unsigned PanelHeight[PanelCount]{512,320,320,512,256,320,256,256,256,256,256,256};
private:
    template<class T> using Ptr=Microsoft::WRL::ComPtr<T>;
    Ptr<ID3D11Resource> candidate_;
    ID3D11DeviceContext* candidateContext_=nullptr;
    std::array<Ptr<ID3D11Resource>,PanelCount+SelectorCount> targets_;
    const void* panelOwner_=nullptr;
    const void* selectorOwner_=nullptr;
    Ptr<ID3D11Resource> bound_;
    ID3D11DeviceContext* boundContext_=nullptr;
    ID3D11DeviceContext* context_=nullptr;
    struct BlendPair { Ptr<ID3D11BlendState> source, alpha; };
    std::vector<BlendPair> blends_;
    bool RejectCandidate() {
        candidate_.Reset();candidateContext_=nullptr;return false;
    }
    void UpdateOwner(const void* owner,const void*& previous,unsigned first,unsigned count) {
        if(owner==previous) return;
        for(unsigned i=first;i<first+count;++i) targets_[i].Reset();
        previous=owner;
    }
    bool RegisterTarget(unsigned index,unsigned width,unsigned height) {
        auto candidate=std::move(candidate_);
        auto* context=candidateContext_;candidateContext_=nullptr;
        if(index>=targets_.size() || !candidate || !context) return false;
        Ptr<ID3D11Texture2D> texture;if(FAILED(candidate.As(&texture))) return false;
        D3D11_TEXTURE2D_DESC d{};texture->GetDesc(&d);
        if(d.Width!=width || d.Height!=height) return false;
        targets_[index]=std::move(candidate);context_=context;
        Ptr<ID3D11RenderTargetView> target;context_->OMGetRenderTargets(1,&target,nullptr);
        ID3D11RenderTargetView* current=target.Get();Targets(context_,1,&current);
        return true;
    }
public:
    ID3D11Resource* PanelResource(unsigned index) const {
        return index<PanelCount ? targets_[index].Get() : nullptr;
    }
    void Clear(ID3D11DeviceContext* context,ID3D11RenderTargetView* target,const FLOAT rgba[4]) {
        candidate_.Reset();candidateContext_=nullptr;
        if (!context || !target || !rgba || rgba[0]!=0 || rgba[1]!=0 || rgba[2]!=0 || rgba[3]!=0) return;
        Ptr<ID3D11Resource> resource;target->GetResource(&resource);
        Ptr<ID3D11Texture2D> texture;if(FAILED(resource.As(&texture))) return;
        D3D11_TEXTURE2D_DESC d{};texture->GetDesc(&d);
        if ((d.Format!=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB && d.Format!=DXGI_FORMAT_R8G8B8A8_TYPELESS)
            || d.SampleDesc.Count!=1) return;
        bool known=d.Width==768 && d.Height==768;
        for(unsigned i=0;i<PanelCount;++i) known|=d.Width==PanelWidth[i] && d.Height==PanelHeight[i];
        if(!known) return;
        candidate_=resource;candidateContext_=context;
    }
    bool RegisterPanel(int index,const void* owner,const void* expectedOwner,float width,float height) {
        UpdateOwner(expectedOwner,panelOwner_,0,PanelCount);
        if(!expectedOwner || owner!=expectedOwner || index<0 || index>=static_cast<int>(PanelCount)) return RejectCandidate();
        const unsigned expectedWidth=PanelWidth[index],expectedHeight=PanelHeight[index];
        if(width!=expectedWidth || height!=expectedHeight) return RejectCandidate();
        return RegisterTarget(static_cast<unsigned>(index),expectedWidth,expectedHeight);
    }
    bool RegisterSelector(int hand,const void* owner,const void* expectedOwner,float width,float height) {
        UpdateOwner(expectedOwner,selectorOwner_,PanelCount,SelectorCount);
        if(!expectedOwner || owner!=expectedOwner || hand<0 || hand>=static_cast<int>(SelectorCount)
            || width!=768 || height!=768) return RejectCandidate();
        return RegisterTarget(PanelCount+static_cast<unsigned>(hand),768,768);
    }
    void Targets(ID3D11DeviceContext* context,UINT count,ID3D11RenderTargetView* const* targets) {
        bound_.Reset();boundContext_=nullptr;
        if(count!=1 || !targets || !targets[0]) return;
        Ptr<ID3D11Resource> resource;targets[0]->GetResource(&resource);
        for(const auto& panel:targets_) if(panel && panel.Get()==resource.Get()) {
            bound_=resource;boundContext_=context;break;
        }
    }
    struct DrawScope {
        ID3D11DeviceContext* context=nullptr;
        Ptr<ID3D11BlendState> original;
        FLOAT factors[4]{};UINT mask=0;
        ~DrawScope() { if(context) context->OMSetBlendState(original.Get(),factors,mask); }
    };
    void BeforeDraw(ID3D11DeviceContext* context,DrawScope& scope) {
        if(context!=context_ || context!=boundContext_ || !bound_) return;
        bool owned=false;for(const auto& panel:targets_) owned|=panel && panel.Get()==bound_.Get();
        if(!owned) return;
        context->OMGetBlendState(&scope.original,scope.factors,&scope.mask);
        if(!scope.original) return;
        D3D11_BLEND_DESC d{};scope.original->GetDesc(&d);auto& rt=d.RenderTarget[0];
        const bool keepsAlpha=rt.RenderTargetWriteMask==7 || (rt.RenderTargetWriteMask==15
            && rt.SrcBlendAlpha==D3D11_BLEND_ZERO && rt.DestBlendAlpha==D3D11_BLEND_ONE && rt.BlendOpAlpha==D3D11_BLEND_OP_ADD);
        if(!rt.BlendEnable || !keepsAlpha
            || rt.SrcBlend!=D3D11_BLEND_SRC_ALPHA || rt.DestBlend!=D3D11_BLEND_INV_SRC_ALPHA
            || rt.BlendOp!=D3D11_BLEND_OP_ADD) return;
        ID3D11BlendState* alpha=nullptr;
        for(const auto& pair:blends_) if(pair.source.Get()==scope.original.Get()) { alpha=pair.alpha.Get();break; }
        if(!alpha) {
            rt.RenderTargetWriteMask=D3D11_COLOR_WRITE_ENABLE_ALL;
            rt.SrcBlendAlpha=D3D11_BLEND_ONE;rt.DestBlendAlpha=D3D11_BLEND_INV_SRC_ALPHA;rt.BlendOpAlpha=D3D11_BLEND_OP_ADD;
            Ptr<ID3D11Device> device;context->GetDevice(&device);
            BlendPair pair;pair.source=scope.original;
            if(FAILED(device->CreateBlendState(&d,&pair.alpha))) return;
            alpha=pair.alpha.Get();blends_.push_back(std::move(pair));
        }
        scope.context=context;context->OMSetBlendState(alpha,scope.factors,scope.mask);
    }
};
}
