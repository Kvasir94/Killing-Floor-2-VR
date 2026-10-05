#pragma once
#include <d3d11.h>
#include <wrl/client.h>
#include <DirectXMath.h>
#include <filesystem>
#include <string>
#include <vector>
#include "kf2vr/Transform.h"

// This diagnostic scene uses raw XR coordinates (metres, +Y up, -Z forward).
// It deliberately does not depend on the provisional KF2 world-unit scale.
class SmokeScene {
public:
    bool Initialise(ID3D11Device* device, std::string& error);
    bool Render(ID3D11DeviceContext* context, ID3D11RenderTargetView* color,
                ID3D11DepthStencilView* depth, unsigned width, unsigned height,
                const kf2vr::Quat& eyeRotation, const kf2vr::Vec3& eyePosition,
                float leftRadians, float rightRadians, float downRadians, float upRadians,
                const kf2vr::Vec3* leftHand = nullptr, const kf2vr::Vec3* rightHand = nullptr);
    static bool Capture(ID3D11DeviceContext* context, ID3D11Texture2D* texture,
                        const std::filesystem::path& path, std::string& error,
                        std::vector<unsigned char>* pixels = nullptr);
    static DirectX::XMMATRIX Projection(float left, float right, float down, float up);
private:
    void Cube(ID3D11DeviceContext* context, DirectX::FXMMATRIX viewProjection,
              float x, float y, float z, float sx, float sy, float sz,
              float red, float green, float blue);
    Microsoft::WRL::ComPtr<ID3D11VertexShader> vertexShader_;
    Microsoft::WRL::ComPtr<ID3D11PixelShader> pixelShader_;
    Microsoft::WRL::ComPtr<ID3D11InputLayout> layout_;
    Microsoft::WRL::ComPtr<ID3D11Buffer> vertices_, constants_;
    Microsoft::WRL::ComPtr<ID3D11RasterizerState> rasterizer_;
    Microsoft::WRL::ComPtr<ID3D11DepthStencilState> depthState_;
};
