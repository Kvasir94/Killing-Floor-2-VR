#include "AtlasBlit.h"
#include <windows.h>
#include <d3d11_1.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <stdexcept>

namespace kf2vr::adapter {
namespace {
using Microsoft::WRL::ComPtr;
void Check(HRESULT result, const char* operation) {
    if (FAILED(result)) {
        char message[160];
        std::snprintf(message, sizeof(message), "%s failed (HRESULT 0x%08lX)", operation, static_cast<unsigned long>(result));
        throw std::runtime_error(message);
    }
}
struct ColourFormats { DXGI_FORMAT storage, linear, srgb; };
ColourFormats Formats(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8G8B8A8_TYPELESS:
    case DXGI_FORMAT_R8G8B8A8_UNORM:
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:
        return {DXGI_FORMAT_R8G8B8A8_TYPELESS, DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB};
    case DXGI_FORMAT_B8G8R8A8_TYPELESS:
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB:
        return {DXGI_FORMAT_B8G8R8A8_TYPELESS, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB};
    case DXGI_FORMAT_B8G8R8X8_TYPELESS:
    case DXGI_FORMAT_B8G8R8X8_UNORM:
    case DXGI_FORMAT_B8G8R8X8_UNORM_SRGB:
        return {DXGI_FORMAT_B8G8R8X8_TYPELESS, DXGI_FORMAT_B8G8R8X8_UNORM, DXGI_FORMAT_B8G8R8X8_UNORM_SRGB};
    default: throw std::runtime_error("Atlas source must be RGBA8/BGRA8/BGRX8 UNORM, sRGB, or typeless");
    }
}
constexpr char kShader[] = R"(
Texture2D<float4> atlas : register(t0);
Texture2D<float4> worldAtlas : register(t1);
SamplerState linearClamp : register(s0);
cbuffer EyeRect : register(b0) {
    float4 scaleOffset; float4 safeBounds;
    float4 eyeOrigin; // w: spatial menu mode
    float4 rayTopLeft; float4 rayAcross; float4 rayDown;
    float4 panel; // width, height, cursor u, cursor v
    float4 cursor; // hit, down, tracked beam visible, curve radius (0: flat)
    float4 beamStart; float4 beamEnd;
    float4 worldScaleOffset; // xy scale, z offset, w: stereo background available
    float4 worldSafeBounds;
    float4 effectOrigin; float4 effectTopLeft; float4 effectAcross; float4 effectDown;
    float4 effects0; // reserved, fire, damage, heal
    float4 effects1; // reserved, rage, flash, night vision
    float4 effectTime; // real seconds, inventory focus, reserved, teleport blink
};
struct Vertex { float4 position : SV_Position; float2 uv : TEXCOORD0; };
Vertex VS(uint id : SV_VertexID) {
    Vertex o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = uv;
    return o;
}
)"
R"(
// Panel-space hit in the panel's own 2D frame: x is arc length along a curved
// panel (the plane's x when flat), y is height. Must match
// IntersectSpatialMenu exactly, or the cursor drifts from the beam.
bool MenuSurface(float3 origin, float3 ray, out float2 planar) {
    planar = 0;
    float R = cursor.w;
    if (R <= .01) {
        float3 hit = origin - ray * (origin.z / ray.z);
        planar = hit.xy;
        return true;
    }
    float2 q = float2(origin.x, origin.z - R), d = ray.xz;
    float a = dot(d, d), b = dot(q, d), c = dot(q, q) - R*R;
    float disc = b*b - a*c;
    if (a <= 1e-8 || disc <= 0) return false;
    float root = sqrt(disc);
    float t = c > 0 ? (-b - root) / a : (-b + root) / a;
    float3 hit = origin + ray * t;
    if (t <= 0 || R - hit.z <= 0) return false;
    planar = float2(R * atan2(hit.x, R - hit.z), hit.y);
    return true;
}
// Stock menus are authored for a monitor. At the panel's angular size the
// headset minifies them slightly, and one bilinear tap shimmers on thin text
// and 1 px rules. Four rotated-grid taps inside the pixel footprint settle it.
float4 SampleMenu(float2 uv) {
    float2 dx = ddx(uv), dy = ddy(uv);
    float4 sum = 0;
    const float2 taps[4] = { float2(.125,.375), float2(-.375,.125), float2(.375,-.125), float2(-.125,-.375) };
    [unroll] for (int i = 0; i < 4; ++i)
        sum += atlas.SampleLevel(linearClamp, clamp(uv + taps[i].x*dx + taps[i].y*dy, safeBounds.xy, safeBounds.zw), 0);
    return sum * .25;
}
float4 PS(Vertex input) : SV_Target {
    if (eyeOrigin.w > .5) {
        float3 ray = rayTopLeft.xyz + input.uv.x*rayAcross.xyz + input.uv.y*rayDown.xyz;
        float3 color = float3(.006, .009, .014);
        if (worldScaleOffset.w > .5) {
            float2 worldUV = clamp(input.uv * worldScaleOffset.xy + float2(worldScaleOffset.z,0),
                                  worldSafeBounds.xy, worldSafeBounds.zw);
            color = worldAtlas.Sample(linearClamp, worldUV).rgb;
        } else {
            // Studio backdrop in KF2's menu palette, anchored in tracking
            // space: the stock menus' near-black maroon with a dim red glow
            // at the horizon, crossed by their slow wavy scanlines. Linear.
            float3 dir = normalize(ray);
            float horizonFactor = exp(-abs(dir.y) * 4.5);
            float3 zenithColor = float3(0.004, 0.0018, 0.0020);
            float3 horizonColor = float3(0.030, 0.0055, 0.0065);
            float3 nadirColor = float3(0.0025, 0.0012, 0.0013);
            color = lerp(dir.y > 0 ? zenithColor : nadirColor, horizonColor, horizonFactor);
            // About 1.4 degree bands, gently bent: world-fixed, so no swim.
            float waves = .5 + .5*sin(dir.y*260 + sin(dir.x*7 + dir.z*5)*2.2);
            color *= .80 + .20*waves;

            // 2. Grounded 3D spatial floor grid (vestibular stability)
            // eyeOrigin is panel-local, and the panel is anchored once when the
            // menu opens, so a constant here is a floor fixed in tracking space
            // 1.45 m below the opening eye height. Deriving it from the live
            // eyeOrigin.y instead made the floor ride the head one-for-one and
            // destroyed the stationary reference this grid exists to provide.
            float floorY = -1.45;
            if (ray.y < -0.01) {
                float tFloor = (floorY - eyeOrigin.y) / ray.y;
                if (tFloor > 0.1) {
                    float3 floorPos = eyeOrigin.xyz + ray * tFloor;
                    float distPlayer = length(floorPos.xz - eyeOrigin.xz);
                    // 0.5m grid lines with anti-aliasing
                    float2 gridUV = floorPos.xz * 2.0;
                    float2 gridLines = abs(frac(gridUV - 0.5) - 0.5) / max(fwidth(gridUV), 0.001);
                    float gridLine = 1.0 - saturate(min(gridLines.x, gridLines.y));
                    float ringPhase = abs(frac(distPlayer * 1.5 - 0.5) - 0.5) / max(fwidth(distPlayer * 1.5), 0.001);
                    float rings = 1.0 - saturate(ringPhase);
                    float floorFade = exp(-distPlayer * 0.40) * saturate(-dir.y * 6.0);
                    float3 gridColor = float3(0.070, 0.010, 0.012) * (gridLine * 0.7 + rings * 0.3) * floorFade;
                    color += gridColor;
                }
            }

            // 3. A few slow embers rising through the space; warm, sparse
            // and far below text contrast.
            [unroll] for (int k = 0; k < 6; ++k) {
                float f = float(k);
                float phase = frac(effectTime.x * 0.04 + f * 0.166);
                float3 center = float3(sin(f * 2.3) * 0.9, -0.4 + phase * 1.1, -0.6 - f * 0.18);
                float along = max(0.0, dot(center - eyeOrigin.xyz, ray));
                float dist = length(eyeOrigin.xyz + ray * along - center);
                float mote = exp(-dist * dist / 0.0008) * sin(phase * 3.141593);
                color += float3(0.30, 0.075, 0.012) * mote * sin(phase * 3.141593) * 0.35;
            }
        }
        float2 hit;
        if (eyeOrigin.z > .01 && ray.z < -.00001 && MenuSurface(eyeOrigin.xyz, ray, hit)) {
            float2 uv = float2(.5 + hit.x/panel.x, .5 - hit.y/panel.y);
            if (worldScaleOffset.w > .5) {
                // Stock / diagnostic live world mode: preserve exact rectangular cutout for regression tests
                if (all(uv >= 0) && all(uv <= 1)) {
                    color = atlas.Sample(linearClamp, clamp(uv, safeBounds.xy, safeBounds.zw)).rgb;
                    if (cursor.x > .5) {
                        float radius = length((uv-panel.zw)*panel.xy);
                        float aa = max(fwidth(radius), .0003);
                        float ring = 1-smoothstep(.001, .001+aa, abs(radius-.009));
                        float dot = 1-smoothstep(.002, .002+aa, radius);
                        float3 tint = cursor.y > .5 ? float3(1,.42,.05) : float3(.82,.80,.74);
                        color = lerp(color, tint, max(ring,dot));
                    }
                }
            } else {
                // Premium VR Native Spatial Panel
                float2 halfSize = panel.xy * 0.5;
                float2 p = abs(hit.xy) - halfSize;
                float r = 0.025; // 2.5cm corner radius
                float d = length(max(p + r, 0.0)) + min(max(p.x + r, p.y + r), 0.0) - r;

                // Soft ambient back-glow / halo behind panel
                if (d > 0.0) {
                    float glow = exp(-d * 20.0) * 0.06;
                    color += float3(0.16, 0.018, 0.022) * glow;
                } else {
                    // Inside rounded panel:
                    // Charcoal backing plate, as behind the stock menus
                    float vGrad = saturate(0.5 - hit.y / panel.y);
                    float3 plateColor = lerp(float3(0.028, 0.032, 0.038), float3(0.016, 0.018, 0.022), vGrad);

                    if (all(uv >= 0.0) && all(uv <= 1.0)) {
                        float4 ui = SampleMenu(uv);
                        float uiAlpha = saturate(max(ui.a, max(ui.r, max(ui.g, ui.b)) > 0.02 ? 1.0 : 0.0));
                        color = lerp(plateColor, ui.rgb, uiAlpha);
                    } else {
                        color = plateColor;
                    }

                    // Elegant Horzine chamfered edge trim / border bezel
                    float edgeDist = abs(d);
                    float edgeAA = max(fwidth(d), 0.0005);
                    float edgeTrim = 1.0 - smoothstep(0.001, 0.003 + edgeAA, edgeDist);
                    float3 trimColor = cursor.y > 0.5 ? float3(0.80, 0.42, 0.06) : float3(0.24, 0.008, 0.012);
                    color = lerp(color, trimColor, edgeTrim * 0.75);

                    // Cursor ring and dot
                    if (cursor.x > .5) {
                        float radius = length((uv-panel.zw)*panel.xy);
                        float aa = max(fwidth(radius), .0003);
                        float ring = 1-smoothstep(.001, .001+aa, abs(radius-.009));
                        float dot = 1-smoothstep(.002, .002+aa, radius);
                        float3 tint = cursor.y > .5 ? float3(1,.42,.05) : float3(.82,.80,.74);
                        color = lerp(color, tint, max(ring,dot));
                    }
                }
            }
        }
        if (cursor.z > .5) {
            // Closest points between the eye ray and the bounded controller
            // beam. Both eyes see the same physical segment, with parallax.
            float3 d = normalize(ray), e = beamEnd.xyz-beamStart.xyz;
            float3 w = eyeOrigin.xyz-beamStart.xyz;
            float ee = max(dot(e,e), .000001), de=dot(d,e);
            float dw=dot(d,w), ew=dot(e,w);
            float s = saturate((ew-de*dw)/max(ee-de*de,.000001));
            float t = max(.01, de*s-dw);
            s = saturate((ew+de*t)/ee);
            t = max(.01, de*s-dw);
            float distance = length(w+d*t-e*s);
            float aa = max(fwidth(distance),.0003);
            float beam = 1-smoothstep(.0015,.0015+aa,distance);
            // KF2 red at rest, amber while the trigger is held.
            color = lerp(color, cursor.y>.5 ? float3(1,.42,.05) : float3(.80,.03,.04),beam*.85);
        }
        // Keep the existing transition fade over the completed menu/world.
        return float4(color*(1-saturate(effectTime.w)),1);
    }
    float2 uv = clamp(input.uv * scaleOffset.xy + scaleOffset.zw, safeBounds.xy, safeBounds.zw);
    return float4(atlas.Sample(linearClamp, uv).rgb*(1-saturate(effectTime.w)), 1);
}
)";
ComPtr<ID3DBlob> Compile(const char* entry, const char* profile) {
    ComPtr<ID3DBlob> shader, diagnostics;
    const HRESULT result = D3DCompile(kShader, sizeof(kShader)-1, "KF2VR AtlasBlit", nullptr, nullptr,
        entry, profile, D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &shader, &diagnostics);
    if (FAILED(result) && diagnostics)
        throw std::runtime_error(std::string("Atlas shader compile: ") + static_cast<const char*>(diagnostics->GetBufferPointer()));
    Check(result, "D3DCompile(AtlasBlit)");
    return shader;
}
} // namespace

struct AtlasBlit::Impl {
    bool fullFrameDiagnostic=false;
    ComfortEffects effects;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext1> context;
    ComPtr<ID3DDeviceContextState> privateState, gameState;
    ComPtr<ID3D11VertexShader> vertex;
    ComPtr<ID3D11PixelShader> pixel;
    ComPtr<ID3D11SamplerState> sampler;
    ComPtr<ID3D11RasterizerState> rasterizer;
    ComPtr<ID3D11DepthStencilState> depthState;
    ComPtr<ID3D11BlendState> blendState;
    ComPtr<ID3D11Buffer> constants;
    ComPtr<ID3D11Texture2D> snapshot;
    ComPtr<ID3D11ShaderResourceView> snapshotView;
    ComPtr<ID3D11ShaderResourceView> frameView;
    ComPtr<ID3D11Resource> frameSource;
    ComPtr<ID3D11ShaderResourceView> backgroundView;
    ComPtr<ID3D11Resource> backgroundSource;
    UINT backgroundWidth = 0, backgroundHeight = 0;
    UINT width = 0, height = 0;
    UINT snapshotWidth = 0, snapshotHeight = 0;
    DXGI_FORMAT storageFormat = DXGI_FORMAT_UNKNOWN, viewFormat = DXGI_FORMAT_UNKNOWN;
    bool active = false;
    std::string error;

    void EndFrame() noexcept {
        if (!active) return;
        // Clear ONLY the private pipeline while it is active. This releases all
        // eye RTV/SRV references before any XR teardown or ResizeBuffers.
        context->ClearState();
        context->SwapDeviceContextState(gameState.Get(), nullptr);
        gameState.Reset();
        frameView.Reset();
        frameSource.Reset();
        backgroundView.Reset();
        backgroundSource.Reset();
        backgroundWidth = backgroundHeight = 0;
        active = false;
    }
    void OnResize() noexcept {
        EndFrame();
        snapshotView.Reset();
        snapshot.Reset();
        width = height = 0;
        snapshotWidth = snapshotHeight = 0;
        storageFormat = viewFormat = DXGI_FORMAT_UNKNOWN;
    }
    void Shutdown() noexcept {
        OnResize();
        constants.Reset();
        blendState.Reset();
        depthState.Reset();
        rasterizer.Reset();
        sampler.Reset();
        pixel.Reset();
        vertex.Reset();
        gameState.Reset();
        privateState.Reset();
        context.Reset();
        device.Reset();
    }
    void Initialise(ID3D11Device* suppliedDevice, ID3D11DeviceContext* suppliedContext) {
        if (!suppliedDevice || !suppliedContext) throw std::runtime_error("AtlasBlit needs a device and immediate context");
        if (suppliedContext->GetType() != D3D11_DEVICE_CONTEXT_IMMEDIATE)
            throw std::runtime_error("AtlasBlit does not support deferred contexts");
        ComPtr<ID3D11Device> contextDevice;
        suppliedContext->GetDevice(&contextDevice);
        if (contextDevice.Get() != suppliedDevice) throw std::runtime_error("AtlasBlit context belongs to a different device");
        if (suppliedDevice->GetFeatureLevel() < D3D_FEATURE_LEVEL_11_0)
            throw std::runtime_error("AtlasBlit requires D3D feature level 11.0");
        device = suppliedDevice;
        Check(suppliedContext->QueryInterface(IID_PPV_ARGS(&context)), "QueryInterface(ID3D11DeviceContext1): state preservation required");
        ComPtr<ID3D11Device1> device1;
        Check(device.As(&device1), "QueryInterface(ID3D11Device1)");
        const D3D_FEATURE_LEVEL level = std::min(device->GetFeatureLevel(), D3D_FEATURE_LEVEL_11_1);
        const UINT flags = (device->GetCreationFlags() & D3D11_CREATE_DEVICE_SINGLETHREADED)
            ? D3D11_1_CREATE_DEVICE_CONTEXT_STATE_SINGLETHREADED : 0u;
        Check(device1->CreateDeviceContextState(flags, &level, 1, D3D11_SDK_VERSION,
            __uuidof(ID3D11Device), nullptr, &privateState), "CreateDeviceContextState");
        const auto vs = Compile("VS", "vs_5_0");
        const auto ps = Compile("PS", "ps_5_0");
        Check(device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &vertex), "CreateVertexShader");
        Check(device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &pixel), "CreatePixelShader");
        D3D11_SAMPLER_DESC sampling{};
        sampling.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
        sampling.AddressU = sampling.AddressV = sampling.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
        sampling.MaxLOD = D3D11_FLOAT32_MAX;
        sampling.ComparisonFunc = D3D11_COMPARISON_NEVER;
        Check(device->CreateSamplerState(&sampling, &sampler), "CreateSamplerState");
        D3D11_RASTERIZER_DESC raster{};
        raster.FillMode = D3D11_FILL_SOLID;
        raster.CullMode = D3D11_CULL_NONE;
        raster.DepthClipEnable = TRUE;
        Check(device->CreateRasterizerState(&raster, &rasterizer), "CreateRasterizerState");
        D3D11_DEPTH_STENCIL_DESC depth{};
        depth.DepthEnable = FALSE;
        depth.DepthWriteMask = D3D11_DEPTH_WRITE_MASK_ZERO;
        depth.DepthFunc = D3D11_COMPARISON_ALWAYS;
        Check(device->CreateDepthStencilState(&depth, &depthState), "CreateDepthStencilState");
        D3D11_BLEND_DESC blend{};
        blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
        Check(device->CreateBlendState(&blend, &blendState), "CreateBlendState");
        D3D11_BUFFER_DESC buffer{};
        buffer.ByteWidth = 76*sizeof(float);
        buffer.Usage = D3D11_USAGE_DEFAULT;
        buffer.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        Check(device->CreateBuffer(&buffer, nullptr, &constants), "CreateBuffer(eye UV rectangle)");
    }

    D3D11_TEXTURE2D_DESC SourceDescription(ID3D11Texture2D* source) const {
        if (!source) throw std::runtime_error("AtlasBlit source texture is null");
        ComPtr<ID3D11Device> sourceDevice;
        source->GetDevice(&sourceDevice);
        if (sourceDevice.Get() != device.Get()) throw std::runtime_error("AtlasBlit source is on another device");
        D3D11_TEXTURE2D_DESC desc{};
        source->GetDesc(&desc);
        if (desc.Width < 2 || (!fullFrameDiagnostic && (desc.Width & 1) != 0) || desc.Height == 0 || desc.ArraySize != 1 || desc.MipLevels != 1)
            throw std::runtime_error("AtlasBlit requires one nonempty single-mip texture; stereo atlas width must be even");
        return desc;
    }

    void PrepareSnapshot(ID3D11Texture2D* source, bool sourceIsSrgb) {
        const auto desc = SourceDescription(source);
        const auto formats = Formats(desc.Format);
        const auto requestedView = sourceIsSrgb ? formats.srgb : formats.linear;
        if (!snapshotView || snapshotWidth != desc.Width || snapshotHeight != desc.Height || storageFormat != formats.storage || viewFormat != requestedView) {
            snapshotView.Reset();
            snapshot.Reset();
            D3D11_TEXTURE2D_DESC copy{};
            copy.Width = desc.Width;
            copy.Height = desc.Height;
            copy.MipLevels = copy.ArraySize = 1;
            copy.Format = formats.storage;
            copy.SampleDesc.Count = 1;
            copy.Usage = D3D11_USAGE_DEFAULT;
            copy.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            Check(device->CreateTexture2D(&copy, nullptr, &snapshot), "CreateTexture2D(atlas snapshot)");
            D3D11_SHADER_RESOURCE_VIEW_DESC view{};
            view.Format = requestedView;
            view.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2D;
            view.Texture2D.MipLevels = 1;
            Check(device->CreateShaderResourceView(snapshot.Get(), &view, &snapshotView), "CreateShaderResourceView(atlas)");
            snapshotWidth = desc.Width;
            snapshotHeight = desc.Height;
            storageFormat = formats.storage;
            viewFormat = requestedView;
        }
        if (desc.SampleDesc.Count > 1) {
            // Resolve requires the exact typed source format if the source is
            // typed. For typeless input, the explicit colour policy chooses it.
            const DXGI_FORMAT resolve = desc.Format == formats.storage ? requestedView : desc.Format;
            UINT support = 0;
            Check(device->CheckFormatSupport(resolve, &support), "CheckFormatSupport(MSAA resolve)");
            if (!(support & D3D11_FORMAT_SUPPORT_MULTISAMPLE_RESOLVE))
                throw std::runtime_error("Atlas source colour format cannot be MSAA-resolved");
            context->ResolveSubresource(snapshot.Get(), 0, source, 0, resolve);
        } else {
            context->CopyResource(snapshot.Get(), source);
        }
        Check(device->GetDeviceRemovedReason(), "D3D11 device health after atlas copy");
        width = desc.Width;
        height = desc.Height;
        frameView = snapshotView;
        frameSource = snapshot;
    }

    void PrepareView(ID3D11ShaderResourceView* sourceView, bool sourceIsSrgb) {
        if (!sourceView) throw std::runtime_error("AtlasBlit source view is null");
        D3D11_SHADER_RESOURCE_VIEW_DESC view{};
        sourceView->GetDesc(&view);
        if (view.ViewDimension != D3D11_SRV_DIMENSION_TEXTURE2D ||
            view.Texture2D.MostDetailedMip != 0 || view.Texture2D.MipLevels != 1)
            throw std::runtime_error("AtlasBlit direct source requires a single Texture2D mip-0 view");
        ComPtr<ID3D11Resource> resource;
        sourceView->GetResource(&resource);
        ComPtr<ID3D11Texture2D> source;
        Check(resource.As(&source), "QueryInterface(atlas texture)");
        const auto desc = SourceDescription(source.Get());
        if (desc.SampleDesc.Count != 1 || !(desc.BindFlags & D3D11_BIND_SHADER_RESOURCE))
            throw std::runtime_error("AtlasBlit direct source must be single-sample and shader-readable");
        const auto formats = Formats(desc.Format);
        if (view.Format != (sourceIsSrgb ? formats.srgb : formats.linear))
            throw std::runtime_error("AtlasBlit source view does not match the explicit sRGB/linear policy");
        width = desc.Width;
        height = desc.Height;
        frameView = sourceView;
        frameSource = resource;
    }

    void PrepareBackground(ID3D11ShaderResourceView* sourceView, bool sourceIsSrgb,
                           ID3D11Texture2D* menuImage) {
        if (!sourceView) throw std::runtime_error("Spatial menu requires a completed stereo background view");
        D3D11_SHADER_RESOURCE_VIEW_DESC view{};
        sourceView->GetDesc(&view);
        if (view.ViewDimension != D3D11_SRV_DIMENSION_TEXTURE2D ||
            view.Texture2D.MostDetailedMip != 0 || view.Texture2D.MipLevels != 1)
            throw std::runtime_error("Spatial menu background requires a single Texture2D mip-0 view");
        ComPtr<ID3D11Resource> resource;
        sourceView->GetResource(&resource);
        ComPtr<ID3D11Texture2D> source;
        Check(resource.As(&source), "QueryInterface(menu background texture)");
        const auto desc = SourceDescription(source.Get());
        if ((desc.Width & 1) || desc.SampleDesc.Count != 1 || !(desc.BindFlags & D3D11_BIND_SHADER_RESOURCE))
            throw std::runtime_error("Spatial menu background must be an even-width single-sample stereo atlas");
        if (resource.Get() == frameSource.Get() || source.Get() == menuImage)
            throw std::runtime_error("Spatial menu image cannot also be its stereo background");
        const auto formats = Formats(desc.Format);
        if (view.Format != (sourceIsSrgb ? formats.srgb : formats.linear))
            throw std::runtime_error("Spatial menu background view does not match its sRGB/linear policy");
        backgroundWidth = desc.Width; backgroundHeight = desc.Height;
        backgroundView = sourceView; backgroundSource = resource;
    }

    void RenderEye(const xr::D3D11EyeTarget& target, const xr::FrameState* frame=nullptr,
                   const SpatialMenuPanel* panel=nullptr, const SpatialMenuPointer* pointer=nullptr) {
        if (!active || !frameView) throw std::runtime_error("AtlasBlit RenderEye requires an active frame");
        if (!target.colorView || target.width == 0 || target.height == 0)
            throw std::runtime_error("AtlasBlit received an empty eye render target");
        D3D11_RENDER_TARGET_VIEW_DESC targetDesc{};
        target.colorView->GetDesc(&targetDesc);
        if (targetDesc.Format != DXGI_FORMAT_R8G8B8A8_UNORM_SRGB && targetDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
            throw std::runtime_error("AtlasBlit requires an sRGB XR render target to encode linear shader output");
        ComPtr<ID3D11Device> targetDevice;
        target.colorView->GetDevice(&targetDevice);
        if (targetDevice.Get() != device.Get()) throw std::runtime_error("AtlasBlit target is on another device");
        ComPtr<ID3D11Resource> targetResource;
        target.colorView->GetResource(&targetResource);
        if (targetResource.Get() == frameSource.Get() || targetResource.Get() == backgroundSource.Get())
            throw std::runtime_error("AtlasBlit target aliases its source texture");
        const float offset = fullFrameDiagnostic || target.eye == xr::Eye::Left ? 0.f : .5f;
        const float scale = fullFrameDiagnostic ? 1.f : .5f;
        const float halfX = .5f / static_cast<float>(width);
        const float halfY = .5f / static_cast<float>(height);
        float data[76]{scale, 1.f, offset, 0.f, offset+halfX, halfY, offset+scale-halfX, 1.f-halfY};
        // Retired status channels remain zero. Transition fades need no eye ray
        // and must still work on the frame where tracking goes away.
        data[75]=std::isfinite(effects.blink)?std::clamp(effects.blink,0.f,1.f):0.f;
        if (panel) {
            if (!fullFrameDiagnostic || !panel->valid || panel->width<=0 || panel->height<=0 ||
                !frame || !frame->viewsValid || !pointer)
                throw std::runtime_error("Spatial menu requires a full image and valid paired views/panel");
            const auto inverse=panel->rotation.Inverse();
            const auto fill=[&](const auto& eye) {
                if (!eye.poseValid) throw std::runtime_error("Spatial menu eye pose unavailable");
                const auto position=inverse.Rotate(eye.pose.pos-panel->center);
                const auto rotation=inverse*eye.pose.rot;
                const float left=std::tan(eye.fov.angleLeft),right=std::tan(eye.fov.angleRight);
                const float up=std::tan(eye.fov.angleUp),down=std::tan(eye.fov.angleDown);
                const auto tl=rotation.Rotate({left,up,-1});
                const auto across=rotation.Rotate({right-left,0,0});
                const auto downward=rotation.Rotate({0,down-up,0});
                const auto put=[&](unsigned i,const Vec3& v) { data[i]=v.x; data[i+1]=v.y; data[i+2]=v.z; };
                put(8,position); data[11]=1;
                put(12,tl); put(16,across); put(20,downward);
                put(32,inverse.Rotate(pointer->rayStart-panel->center));
                put(36,inverse.Rotate(pointer->rayEnd-panel->center));
            };
            if (target.eye==xr::Eye::Left) fill(frame->eyeLeft); else fill(frame->eyeRight);
            data[24]=panel->width; data[25]=panel->height;
            data[26]=pointer->u; data[27]=pointer->v;
            data[28]=pointer->hit?1.f:0.f; data[29]=pointer->down?1.f:0.f;
            data[30]=pointer->rayVisible?1.f:0.f;
            data[31]=std::isfinite(panel->curveRadius) && panel->curveRadius>.01f ? panel->curveRadius : 0.f;
            if (backgroundView) {
                const float worldOffset=target.eye==xr::Eye::Left ? 0.f : .5f;
                const float worldHalfX=.5f/static_cast<float>(backgroundWidth);
                const float worldHalfY=.5f/static_cast<float>(backgroundHeight);
                data[40]=.5f; data[41]=1.f; data[42]=worldOffset; data[43]=1.f;
                data[44]=worldOffset+worldHalfX; data[45]=worldHalfY;
                data[46]=worldOffset+.5f-worldHalfX; data[47]=1.f-worldHalfY;
            }
            for (const auto value:data) if (!std::isfinite(value))
                throw std::runtime_error("Spatial menu has nonfinite geometry");
        }
        context->UpdateSubresource(constants.Get(), 0, nullptr, data, 0, 0);
        const D3D11_VIEWPORT viewport{0.f, 0.f, static_cast<float>(target.width), static_cast<float>(target.height), 0.f, 1.f};
        context->RSSetViewports(1, &viewport);
        context->RSSetState(rasterizer.Get());
        context->OMSetRenderTargets(1, &target.colorView, nullptr);
        context->OMSetBlendState(blendState.Get(), nullptr, 0xffffffffu);
        context->OMSetDepthStencilState(depthState.Get(), 0);
        context->IASetInputLayout(nullptr);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vertex.Get(), nullptr, 0);
        context->PSSetShader(pixel.Get(), nullptr, 0);
        context->HSSetShader(nullptr, nullptr, 0);
        context->DSSetShader(nullptr, nullptr, 0);
        context->GSSetShader(nullptr, nullptr, 0);
        ID3D11Buffer* buffer = constants.Get();
        ID3D11SamplerState* sampling = sampler.Get();
        ID3D11ShaderResourceView* sources[]{frameView.Get(), backgroundView.Get()};
        context->PSSetConstantBuffers(0, 1, &buffer);
        context->PSSetSamplers(0, 1, &sampling);
        context->PSSetShaderResources(0, 2, sources);
        context->Draw(3, 0);
        // Callback lifetime never pins XR images in the private context state.
        context->OMSetRenderTargets(0, nullptr, nullptr);
        ID3D11ShaderResourceView* empty[2]{};
        context->PSSetShaderResources(0, 2, empty);
        Check(device->GetDeviceRemovedReason(), "D3D11 device health after atlas blit");
    }
};

AtlasBlit::AtlasBlit() : impl_(std::make_unique<Impl>()) {}
AtlasBlit::~AtlasBlit() { impl_->Shutdown(); }
bool AtlasBlit::Initialise(ID3D11Device* device, ID3D11DeviceContext* context) {
    impl_->Shutdown();
    impl_->error.clear();
    try { impl_->Initialise(device, context); return true; }
    catch (const std::exception& error) { impl_->error = error.what(); impl_->Shutdown(); return false; }
}
bool AtlasBlit::BeginFrame(ID3D11Texture2D* backBuffer, bool sourceIsSrgb, bool fullFrameDiagnostic) {
    auto& p = *impl_;
    p.error.clear();
    if (!p.privateState || p.active) { p.error = "AtlasBlit BeginFrame requires initialization and no active frame"; return false; }
    p.fullFrameDiagnostic=fullFrameDiagnostic;
    p.context->SwapDeviceContextState(p.privateState.Get(), &p.gameState);
    p.active = true;
    try { p.PrepareSnapshot(backBuffer, sourceIsSrgb); return true; }
    catch (const std::exception& error) { p.error = error.what(); p.EndFrame(); return false; }
}
bool AtlasBlit::BeginFrameView(ID3D11ShaderResourceView* atlasView, bool sourceIsSrgb) {
    auto& p = *impl_;
    p.error.clear();
    if (!p.privateState || p.active) { p.error = "AtlasBlit BeginFrameView requires initialization and no active frame"; return false; }
    p.fullFrameDiagnostic = false;
    p.context->SwapDeviceContextState(p.privateState.Get(), &p.gameState);
    p.active = true;
    try { p.PrepareView(atlasView, sourceIsSrgb); return true; }
    catch (const std::exception& error) { p.error = error.what(); p.EndFrame(); return false; }
}
bool AtlasBlit::BeginMenuFrame(ID3D11Texture2D* menuImage, ID3D11ShaderResourceView* stereoBackgroundView,
                             bool menuIsSrgb, bool backgroundIsSrgb) {
    if (!BeginFrame(menuImage, menuIsSrgb, true)) return false;
    auto& p = *impl_;
    try { p.PrepareBackground(stereoBackgroundView, backgroundIsSrgb, menuImage); return true; }
    catch (const std::exception& error) { p.error = error.what(); p.EndFrame(); return false; }
}
bool AtlasBlit::RenderEye(const xr::D3D11EyeTarget& target) {
    try { impl_->RenderEye(target); return true; }
    catch (const std::exception& error) { impl_->error = error.what(); return false; }
}
void AtlasBlit::SetComfortEffects(const xr::FrameState&,const ComfortEffects& effects) {
    // Status/focus inputs remain in the public bridge for compatibility, but
    // cannot modify the stock world image, even from an older script package.
    impl_->effects={}; impl_->effects.blink=effects.blink;
}
bool AtlasBlit::RenderMenuEye(const xr::D3D11EyeTarget& target, const xr::FrameState& frame,
                            const SpatialMenuPanel& panel, const SpatialMenuPointer& pointer) {
    try { impl_->RenderEye(target,&frame,&panel,&pointer); return true; }
    catch (const std::exception& error) { impl_->error=error.what(); return false; }
}
void AtlasBlit::EndFrame() { impl_->EndFrame(); }
void AtlasBlit::OnResize() { impl_->OnResize(); }
void AtlasBlit::Shutdown() { impl_->Shutdown(); }
const std::string& AtlasBlit::LastError() const { return impl_->error; }
} // namespace kf2vr::adapter
