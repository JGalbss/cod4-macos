// Minimal R_BeginRegistration replacement for the Switch port.
//
// The upstream stub in posix_backbone_stubs.cpp does nothing, leaving
// `frontEndDataOut`, `s_cmdList`, and the inner command-buffer pointers
// inside s_backEndData[] uninitialized. Once we drop the Switch-only
// no-op from SCR_UpdateScreen, the very first R_BeginSharedCmdList
// dereferences those null pointers and the guest faults.
//
// This file fills the bare-minimum slots so the engine's command-pumping
// path can run end to end. No GL is actually called yet — commands are
// pushed into static buffers and discarded by the matching backend
// stubs. Once the queue is reliably populated, the next bite will start
// translating those commands into src/gfx_gl/ draw calls.

#include <cstdint>
#include <cstring>

#ifdef __SWITCH__
#include <switch.h>
#endif

#include "client_mp/client_mp.h"
#include "gfx_d3d/r_rendercmds.h"
#include "gfx_d3d/r_init.h"
#include "gfx_d3d/r_material.h"
#include "gfx_d3d/r_font.h"
#include "gfx_gl/gl_renderer.h"
#include "database/database.h"

// Engine-side globals — defined in src/gfx_d3d/r_rendercmds.cpp, just
// missing their inner allocations because R_InitRenderCommands never ran.
extern GfxBackEndData s_backEndData[2];
extern GfxCmdArray g_frontEndCmds[2];
extern GfxBackEndData *frontEndDataOut;
extern GfxCmdArray *s_cmdList;
extern unsigned int s_smpFrame;
extern unsigned int s_renderCmdBufferSize;
extern int s_renderCmdWarnSize;
extern Font_s *registeredFont[16];
extern int registeredFontCount;

namespace {

// Static command-buffer storage so we don't depend on Hunk / R_AllocGlobalVariable
// during early bring-up. ~1 MiB per frame matches the order of magnitude the
// upstream `s_renderCmdBufferSize = 98304 * maxClientViews` lands on.
constexpr size_t kCmdBufferSize = 1 << 20;
alignas(16) uint8_t g_cmdBuffer[2][kCmdBufferSize];

} // namespace

void R_BeginRegistration(vidConfig_t *vidConfigOut)
{
    for (int i = 0; i < 2; ++i) {
        g_frontEndCmds[i].cmds = g_cmdBuffer[i];
        g_frontEndCmds[i].usedTotal = 0;
        g_frontEndCmds[i].usedCritical = 0;
        g_frontEndCmds[i].lastCmd = nullptr;
        s_backEndData[i].commands = &g_frontEndCmds[i];
    }
    s_smpFrame = 0;
    frontEndDataOut = &s_backEndData[0];
    s_cmdList = &g_frontEndCmds[0];
    s_renderCmdBufferSize = static_cast<int>(kCmdBufferSize);
    s_renderCmdWarnSize = static_cast<int>(kCmdBufferSize) * 3 / 4;

    // Initialise the asset entry pool before we touch DB_AddXAsset —
    // upstream only does this lazily inside DB_LoadXAssets, but we need
    // it earlier so Material_RegisterHandle has somewhere to land.
    extern void DB_Init();
    DB_Init();

    // Register a placeholder $default material so DB_FindXAssetHeader has
    // something to hand back when the engine asks for "white" / "console"
    // / any other unresolved material name. The backing storage stays
    // zeroed — RB_* dispatch will see all-zero state and either no-op or
    // get caught by our switch_dispatch_render_queue translator before
    // touching anything D3D9-only.
    // Self-referencing technique set so Material_GetTechniqueSet (which does
    // material->techniqueSet->remappedTechniqueSet) yields a non-null
    // structure even though we have no real shaders behind it. The render
    // dispatch on Switch will see the zeroed techniques[] and skip the
    // D3D9-only Material_DrawSomeCommandList path.
    static MaterialTechniqueSet s_defaultTechniqueSet{};
    static const char s_defaultTechniqueSetName[] = "$default";
    s_defaultTechniqueSet.name = s_defaultTechniqueSetName;
    s_defaultTechniqueSet.remappedTechniqueSet = &s_defaultTechniqueSet;

    static Material s_defaultMaterial{};
    static const char s_defaultMaterialName[] = "$default";
    s_defaultMaterial.info.name = s_defaultMaterialName;
    s_defaultMaterial.techniqueSet = &s_defaultTechniqueSet;
    XAssetHeader matHeader{};
    matHeader.material = &s_defaultMaterial;
    DB_AddXAsset(ASSET_TYPE_MATERIAL, matHeader);
    // Material_MakeDefault checks rgp.defaultMaterial directly (not the
    // DB) when a name doesn't resolve, so wire it through as well.
    rgp.defaultMaterial = &s_defaultMaterial;
    // Force every Material_RegisterHandle lookup (white, console, gradient_*,
    // ...) to resolve to the default placeholder. Without this, UI_FillRect
    // bails because sharedUiInfo.assets.whiteMaterial is NULL and we never
    // emit any RC_STRETCH_PIC commands — the framebuffer stays empty.
    extern bool g_alwaysUseDefaultMaterial;
    g_alwaysUseDefaultMaterial = true;

    // Same idea for the default console font — R_RegisterFont asks for
    // "fonts/consolefont", so we hand back a placeholder Font_s pointing
    // at the default material we just registered. R_GetCharacterGlyph
    // indexes `glyphs[letter - 32]` for printable ASCII, so we ship 96
    // populated glyph slots (32..127) with a fixed dx; otherwise
    // R_LetterWidth dereferences null at offset 0x58C.
    static Glyph s_defaultGlyphs[96]{};
    for (int i = 0; i < 96; ++i) {
        s_defaultGlyphs[i].letter = static_cast<unsigned short>(32 + i);
        s_defaultGlyphs[i].dx = 8;
        s_defaultGlyphs[i].pixelWidth = 8;
        s_defaultGlyphs[i].pixelHeight = 16;
    }
    static Font_s s_defaultFont{};
    static const char s_defaultFontName[] = "fonts/consolefont";
    s_defaultFont.fontName = s_defaultFontName;
    s_defaultFont.pixelHeight = 16;
    s_defaultFont.glyphCount = 96;
    s_defaultFont.material = &s_defaultMaterial;
    s_defaultFont.glowMaterial = &s_defaultMaterial;
    s_defaultFont.glyphs = s_defaultGlyphs;
    XAssetHeader fontHeader{};
    fontHeader.font = &s_defaultFont;
    DB_AddXAsset(ASSET_TYPE_FONT, fontHeader);
    // R_RegisterFont_LoadObj searches the `registeredFont[]` cache first
    // before trying to FS_FOpenFileRead the font from disk; seed every
    // name the engine asks for so we never reach the disk-read fallback.
    static const char *const s_fontNames[] = {
        "fonts/consolefont",
        "fonts/consoleFont",
        "fonts/smallfont",
        "fonts/bigfont",
        "fonts/extrabigfont",
        "fonts/objectivefont",
        "fonts/normalfont",
        "fonts/boldfont",
    };
    static Font_s s_fontPool[sizeof(s_fontNames)/sizeof(s_fontNames[0])];
    for (size_t i = 0; i < sizeof(s_fontNames)/sizeof(s_fontNames[0]) && i < 16; ++i) {
        s_fontPool[i] = s_defaultFont;
        s_fontPool[i].fontName = s_fontNames[i];
        registeredFont[i] = &s_fontPool[i];
    }
    registeredFontCount = (int)(sizeof(s_fontNames)/sizeof(s_fontNames[0]));
    if (registeredFontCount > 16) registeredFontCount = 16;

    // Generic dummy backing so every other asset type that ships a
    // `g_defaultAssetName[type]` entry can resolve to something
    // non-null. Each dummy struct starts with a `const char *name`
    // pointer (matches XAssetHeader's layout), so we plant the same
    // default-name string in the slot and feed it into DB_AddXAsset.
    //
    // This is enough for the engine's "is the default loaded?" check
    // to succeed; if anything actually tries to read the asset
    // contents (techset/textures/glyphs/...), we'll fault and wire
    // the specific type after that. The list below mirrors
    // db_registry.cpp:g_defaultAssetName but omits the types we have
    // already covered (material, font).
    struct AssetSlot { XAssetType type; const char *defaultName; };
    static const AssetSlot s_slots[] = {
        // Only types whose getter handler reads offset 0 (the COMDAT-
        // folded DB_StringTableGetName family). GfxImage uses offset 32+
        // and other handlers have their own field; leaving those out
        // for now keeps unrelated pointer fields zero instead of carrying
        // our name address and getting dereferenced as a vtable / buf.
        {ASSET_TYPE_PHYSPRESET,            "default"},
        {ASSET_TYPE_TECHNIQUE_SET,         "default"},
        {ASSET_TYPE_MENULIST,              "ui/default.menu"},
        {ASSET_TYPE_MENU,                  "default_menu"},
        {ASSET_TYPE_STRINGTABLE,           "mp/defaultStringTable.csv"},
    };
    for (const AssetSlot &slot : s_slots) {
        static unsigned char s_storage[sizeof(s_slots) / sizeof(s_slots[0])][256] = {};
        static int s_idx = 0;
        unsigned char *buf = s_storage[s_idx++];
        // Only the very first sizeof(char*) bytes get the name pointer; the
        // rest stays zeroed so other pointer-typed struct fields don't
        // alias our name string and get dereferenced.
        *reinterpret_cast<const char **>(buf) = slot.defaultName;
        XAssetHeader hdr{};
        hdr.data = buf;
        DB_AddXAsset(slot.type, hdr);
    }

    // Leaving rg.registered = 0 keeps R_BeginFrame and Material_*Override
    // out of the path (both touch unregistered renderer dvars). We reset
    // the command queue ourselves from switch_main between Com_Frame
    // iterations so RC_* opcodes don't accumulate.

    if (vidConfigOut) {
        *vidConfigOut = cls.vidConfig;
    }

#ifdef __SWITCH__
    static const char msg[] = "[switch_renderer_init] R_BeginRegistration done";
    svcOutputDebugString(msg, sizeof(msg) - 1);
#endif
}

void switch_reset_render_queue()
{
    // Counterpart to what R_BeginFrame + R_ClearCmdList would do upstream.
    for (int i = 0; i < 2; ++i) {
        g_frontEndCmds[i].usedTotal = 0;
        g_frontEndCmds[i].usedCritical = 0;
        g_frontEndCmds[i].lastCmd = nullptr;
    }
}

namespace gfx_gl { void apply_clear_color(float r, float g, float b, float a); }

void switch_dispatch_render_queue()
{
    // Walks the front-end command queue produced by SCR_UpdateScreen and
    // hands off the few opcodes we can already translate into GLES2 calls.
    // Unknown commands fall through so we don't stall the pipeline — they
    // get picked up bite by bite as we wire each RC_* into src/gfx_gl/.
    const GfxCmdArray *list = &g_frontEndCmds[0];
    if (!list->cmds || list->usedTotal <= 0) return;

#ifdef __SWITCH__
    // Roll up which opcodes the engine emits over a window of frames, so
    // we know what to wire next (RC_STRETCH_PIC and RC_DRAW_TEXT_2D are
    // the proof the UI subsystem is putting glyphs in front of us).
    static int s_dispatchFrame = 0;
    int counts[22] = {0};
#endif

    size_t pos = 0;
    while (pos < (size_t)list->usedTotal) {
        const auto *hdr = reinterpret_cast<const GfxCmdHeader *>(list->cmds + pos);
        if (hdr->id == 0 || hdr->byteCount == 0) break;
#ifdef __SWITCH__
        if (hdr->id < 22) ++counts[hdr->id];
#endif
        switch (hdr->id) {
        case 4: { // RC_CLEAR_SCREEN
            const auto *cmd = reinterpret_cast<const GfxCmdClearScreen *>(hdr);
            gfx_gl::clear_now(cmd->color[0], cmd->color[1], cmd->color[2], cmd->color[3]);
            break;
        }
        case 6: { // RC_STRETCH_PIC — material-textured quad. We don't have
                  // textures yet, so draw a flat-colored rect with the cmd's
                  // GfxColor (which carries the item's backcolor).
            const auto *cmd = reinterpret_cast<const GfxCmdStretchPic *>(hdr);
            const float r = cmd->color.array[0] / 255.0f;
            const float g = cmd->color.array[1] / 255.0f;
            const float b = cmd->color.array[2] / 255.0f;
            const float a = cmd->color.array[3] / 255.0f;
            gfx_gl::draw_ui_filled_rect(cmd->x, cmd->y, cmd->w, cmd->h, r, g, b, a);
            break;
        }
        case 13: { // RC_DRAW_TEXT_2D — render with the embedded 8x8 font.
                   // The cmd's text[] is variable-length (charCount + struct
                   // header); the engine packs the string starting at the
                   // declared text[] offset.
            const auto *cmd = reinterpret_cast<const GfxCmdDrawText2D *>(hdr);
            if (cmd->maxChars > 0 && cmd->font) {
                const float charW = 8.0f * cmd->xScale;
                const float charH = 8.0f * cmd->yScale;
                const float r = cmd->color.array[0] / 255.0f;
                const float g = cmd->color.array[1] / 255.0f;
                const float b = cmd->color.array[2] / 255.0f;
                const float a = cmd->color.array[3] / 255.0f;
                // cmd->text is char[3] in the struct, but the engine
                // allocated extra trailing bytes via the size formula
                // `(charCount + 84) & ~3` — the actual null-terminated
                // string starts at &cmd->text[0] and continues past the
                // declared array.
                gfx_gl::draw_ui_text(cmd->x, cmd->y - charH, cmd->text,
                                     charW, charH, r, g, b, a);
            }
            break;
        }
        default:
            break;
        }
        pos += hdr->byteCount;
    }

#ifdef __SWITCH__
    // Log a histogram every ~256 frames so the noise stays low but we
    // catch the moment the UI subsystem starts queuing draw commands.
    ++s_dispatchFrame;
    if ((s_dispatchFrame & 0xFF) == 0) {
        char dbg[256];
        int n = std::snprintf(dbg, sizeof(dbg), "[render-hist] frame=%d:", s_dispatchFrame);
        for (int i = 0; i < 22; ++i) {
            if (counts[i] == 0) continue;
            n += std::snprintf(dbg + n, sizeof(dbg) - n, " %d:%d", i, counts[i]);
            if (n >= (int)sizeof(dbg) - 16) break;
        }
        svcOutputDebugString(dbg, std::strlen(dbg));
    }
#endif
}
