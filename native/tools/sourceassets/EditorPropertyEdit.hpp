#pragma once
#include <cstdint>
#include <string>
#include <vector>

// KFEditor SHA256 b937aadaa06f728354044461cb8490ef2c20b17245535cf88d3f23cd81ddb85c.
// UObject::StaticExec dispatches SET/SETNOPEC to this helper at RVA 0xf0a71.
// Actor.ConsoleCommand blocks SET in the editor before reaching it. Calling the
// same property importer directly preserves native edit notifications without
// changing global editor flags or inventing layouts for native asset arrays.
namespace source_asset_edit {
using FindObject = void* (*)(void*, void*, const wchar_t*, int);
using FindProperty = void* (*)(void*, const wchar_t*);
using ImportPropertyCommand = void (*)(const wchar_t*, void*, int);

inline void* ReadPointer(void* object, std::size_t offset) {
    return *reinterpret_cast<void**>(static_cast<char*>(object) + offset);
}

inline bool OwnedBy(void* object, void* package) {
    for (int depth = 0; object && depth < 8; ++depth) {
        if (object == package) return true;
        object = ReadPointer(object, 0x40);
    }
    return false;
}

inline bool SimplePath(const std::wstring& path) {
    if (path.empty() || path.size() > 255) return false;
    for (wchar_t ch : path)
        if (!((ch >= L'A' && ch <= L'Z') || (ch >= L'a' && ch <= L'z') ||
              (ch >= L'0' && ch <= L'9') || ch == L'_' || ch == L'.' || ch == L':')) return false;
    return true;
}

// Payload: exact object path | property | value | notify (0 or 1).
// Only properties needed to finish this imported art package are accepted.
inline void* Apply(std::uintptr_t base, FindObject find, const std::wstring& packageName,
                   const std::wstring& payload) {
    std::vector<std::wstring> fields;
    std::size_t start = 0;
    for (;;) {
        const auto split = payload.find(L'|', start);
        fields.push_back(payload.substr(start, split == std::wstring::npos ? split : split - start));
        if (split == std::wstring::npos) break;
        start = split + 1;
    }
    if (fields.size() != 4 || (fields[3] != L"0" && fields[3] != L"1")) return nullptr;
    const auto& path = fields[0]; const auto& key = fields[1]; const auto& value = fields[2];
    if (!SimplePath(path) || !path.starts_with(packageName + L".")) return nullptr;
    void* package = find(nullptr, nullptr, packageName.c_str(), 0);
    void* object = find(nullptr, nullptr, path.c_str(), 0);
    if (!package || !object || object == package || !OwnedBy(object, package)) return nullptr;
    void* objectClass = ReadPointer(object, 0x50);
    const wchar_t* propertyClassName = nullptr;
    const wchar_t* expectedClassName = nullptr;
    std::vector<void*> expectedMaterials;
    if (key == L"Materials") {
        expectedClassName = L"Engine.SkeletalMesh";
        propertyClassName = L"Core.ArrayProperty";
        if (value.size() < 3 || value.front() != L'(' || value.back() != L')') return nullptr;
        const std::wstring prefix = L"Material'";
        const auto list = value.substr(1, value.size() - 2);
        std::size_t pos = 0;
        for (;;) {
            const auto end = list.find(L',', pos);
            const auto entry = list.substr(pos, end == std::wstring::npos ? end : end - pos);
            if (!entry.starts_with(prefix) || entry.back() != L'\'') return nullptr;
            const auto materialPath = entry.substr(prefix.size(), entry.size() - prefix.size() - 1);
            if (!SimplePath(materialPath) || !materialPath.starts_with(packageName + L".")) return nullptr;
            void* materialClass = find(nullptr, nullptr, L"Engine.Material", 0);
            void* material = find(materialClass, nullptr, materialPath.c_str(), 1);
            if (!materialClass || !material || !OwnedBy(material, package)) return nullptr;
            expectedMaterials.push_back(material);
            if (expectedMaterials.size() > 8) return nullptr;
            if (end == std::wstring::npos) break;
            pos = end + 1;
        }
    } else if (key == L"TwoSided" || key == L"bLit" || key == L"SRGB") {
        expectedClassName = key == L"TwoSided" ? L"Engine.Material" :
            key == L"bLit" ? L"Engine.ParticleSystem" : L"Engine.Texture2D";
        propertyClassName = L"Core.BoolProperty";
        if (value != L"True" && value != L"False") return nullptr;
    } else if (key == L"CompressionSettings") {
        expectedClassName = L"Engine.Texture2D";
        propertyClassName = L"Core.ByteProperty";
        if (value != L"TC_Normalmap") return nullptr;
    } else if (key == L"LODValidity") {
        propertyClassName = L"Core.ByteProperty";
        if (value != L"1" || fields[3] != L"0") return nullptr;
        void* parent = ReadPointer(object, 0x40);
        void* systemClass = find(nullptr, nullptr, L"Engine.ParticleSystem", 0);
        if (!parent || !systemClass || ReadPointer(parent, 0x50) != systemClass) return nullptr;
    } else return nullptr;
    if (expectedClassName && objectClass != find(nullptr, nullptr, expectedClassName, 0)) return nullptr;
    void* property = reinterpret_cast<FindProperty>(base + 0x73e80)(objectClass, key.c_str());
    void* propertyClass = find(nullptr, nullptr, propertyClassName, 0);
    if (!property || !propertyClass || ReadPointer(property, 0x50) != propertyClass) return nullptr;
    const auto offset = *reinterpret_cast<std::int32_t*>(static_cast<char*>(property) + 0x8c);
    if (offset < 0x60 || offset > 0x100000) return nullptr;
    void* feedback = *reinterpret_cast<void**>(base + 0x3c33ff8);
    if (!feedback) return nullptr;
    const auto command = path + L" " + key + L" " + value;
    reinterpret_cast<ImportPropertyCommand>(base + 0xe5880)(command.c_str(), feedback, fields[3] == L"1");
    if (key == L"LODValidity" && *reinterpret_cast<std::uint8_t*>(static_cast<char*>(object) + offset) != 1)
        return nullptr;
    if (key == L"Materials") {
        struct ObjectArray { void** data; std::int32_t count, capacity; };
        const auto& actual = *reinterpret_cast<ObjectArray*>(static_cast<char*>(object) + offset);
        if (actual.count != static_cast<std::int32_t>(expectedMaterials.size()) ||
            actual.capacity < actual.count || !actual.data) return nullptr;
        for (std::size_t i = 0; i < expectedMaterials.size(); ++i)
            if (actual.data[i] != expectedMaterials[i]) return nullptr;
    }
    return object;
}
} // namespace source_asset_edit
