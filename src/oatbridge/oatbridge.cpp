#include "oatbridge.h"

#include "Pool/XAssetInfo.h"
#include "Zone/Zone.h"
#include "Game/IW3/IW3.h"
#include "ZoneLoading.h"

#include <cstring>
#include <memory>
#include <string>
#include <vector>

struct OatZone
{
    std::unique_ptr<Zone> zone;
    std::vector<XAssetInfoGeneric *> assets;
};

namespace
{
    class BridgeProgressCallback final : public ProgressCallback
    {
    public:
        BridgeProgressCallback(OatProgressCallback callback, void *userData)
            : m_callback(callback), m_userData(userData)
        {
        }

        void OnProgress(const size_t current, const size_t total) override
        {
            m_callback(current, total, m_userData);
        }

    private:
        OatProgressCallback m_callback;
        void *m_userData;
    };
}

OatZone *OAT_LoadZoneWithProgress(const char *path, char *errOut, const int errCap,
                                  OatProgressCallback progress, void *userData)
{
    const auto copyError = [errOut, errCap](const std::string &message)
    {
        if (!errOut || errCap <= 0)
            return;
        std::strncpy(errOut, message.c_str(), static_cast<size_t>(errCap) - 1);
        errOut[errCap - 1] = '\0';
    };

    std::optional<std::unique_ptr<ProgressCallback>> progressCallback;
    if (progress)
        progressCallback = std::make_unique<BridgeProgressCallback>(progress, userData);

    auto loaded = ZoneLoading::LoadZone(path, std::move(progressCallback));
    if (!loaded)
    {
        copyError(loaded.error());
        return nullptr;
    }

    auto out = std::make_unique<OatZone>();
    out->zone = std::move(*loaded);
    // Reference entries name an asset that lives in another zone. OAT leaves them
    // unresolved - it is a dumper, and its registry is only read by the writing side -
    // so they are handed over too, flagged, for the caller to resolve.
    for (auto *asset : out->zone->m_pools)
        out->assets.push_back(asset);

    return out.release();
}

OatZone *OAT_LoadZone(const char *path, char *errOut, const int errCap)
{
    return OAT_LoadZoneWithProgress(path, errOut, errCap, nullptr, nullptr);
}

int OAT_AssetCount(const OatZone *zone)
{
    return zone ? static_cast<int>(zone->assets.size()) : 0;
}

int OAT_AssetAt(const OatZone *zone, const int index, OatAsset *out)
{
    if (!zone || !out || index < 0 || static_cast<size_t>(index) >= zone->assets.size())
        return 0;

    const auto *info = zone->assets[index];
    out->type = static_cast<int>(info->m_type);
    out->name = info->m_name.c_str();
    out->data = info->m_ptr;
    out->isReference = info->IsReference() ? 1 : 0;
    return 1;
}

const char *OAT_ZoneName(const OatZone *zone)
{
    return zone ? zone->zone->m_name.c_str() : "";
}

int OAT_ScriptStringCount(const OatZone *zone)
{
    return zone ? static_cast<int>(zone->zone->m_script_strings.Count()) : 0;
}

const char *OAT_ScriptStringAt(const OatZone *zone, const int index)
{
    if (!zone || index < 0 || static_cast<size_t>(index) >= zone->zone->m_script_strings.Count())
        return nullptr;

    return zone->zone->m_script_strings.CValue(static_cast<size_t>(index));
}

namespace
{
    struct StructInfo
    {
        const char *name;
        unsigned long size;
    };

    const StructInfo kStructs[OAT_STRUCT_COUNT] = {
        {"Material", sizeof(IW3::Material)},
        {"MaterialTechniqueSet", sizeof(IW3::MaterialTechniqueSet)},
        {"GfxImage", sizeof(IW3::GfxImage)},
        {"menuDef_t", sizeof(IW3::menuDef_t)},
        {"itemDef_s", sizeof(IW3::itemDef_s)},
        {"Operand", sizeof(IW3::Operand)},
        {"expressionEntry", sizeof(IW3::expressionEntry)},
        {"statement_s", sizeof(IW3::statement_s)},
        {"XAnimParts", sizeof(IW3::XAnimParts)},
        {"XModel", sizeof(IW3::XModel)},
        {"GfxWorld", sizeof(IW3::GfxWorld)},
        {"clipMap_t", sizeof(IW3::clipMap_t)},
        {"snd_alias_t", sizeof(IW3::snd_alias_t)},
        {"snd_alias_list_t", sizeof(IW3::snd_alias_list_t)},
        {"WeaponDef", sizeof(IW3::WeaponDef)},
    };
}

const char *OAT_StructName(const int id)
{
    return (id >= 0 && id < OAT_STRUCT_COUNT) ? kStructs[id].name : "";
}

unsigned long OAT_StructSize(const int id)
{
    return (id >= 0 && id < OAT_STRUCT_COUNT) ? kStructs[id].size : 0;
}

void OAT_FreeZone(OatZone *zone)
{
    delete zone;
}
