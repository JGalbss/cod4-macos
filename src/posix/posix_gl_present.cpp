#include "posix_gl_present.h"

#include "gfx_d3d/r_dvars.h"
#include "gfx_d3d/r_font.h"
#include "gfx_d3d/r_gfx.h"
#include "gfx_d3d/r_rendercmds.h"
#include "gfx_d3d/rb_backend.h"
#include "gfx_gl/gl_renderer.h"
#include "posix/posix_gl_texture.h"
#include "posix/posix_input.h"
#include "qcommon/qcommon.h"
#include "ui/keycodes.h"
#include "universal/com_files.h"

#include <SDL.h>
#include <SDL_opengl.h>

#include <atomic>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cstdlib>
#include <vector>

namespace posix_gl {
namespace {

SDL_Window *g_window = nullptr;
std::atomic<unsigned long long> g_requestedWindowSize{0};
std::atomic<int> g_requestedFullscreen{-1};
#ifndef KISAK_DXVK
SDL_GLContext g_context = nullptr;
#endif
bool g_ready = false;
int g_displayFrequency = 60;

void UpdateDisplayFrequency()
{
    SDL_DisplayMode displayMode{};
    const int displayIndex = SDL_GetWindowDisplayIndex(g_window);
    if (displayIndex >= 0 && SDL_GetCurrentDisplayMode(displayIndex, &displayMode) == 0
        && displayMode.refresh_rate > 0)
    {
        g_displayFrequency = displayMode.refresh_rate;
    }
}

// The front end double-buffers its command lists, so read the one this frame
// actually wrote rather than assuming index 0.
const GfxCmdArray *CurrentCommands()
{
    return frontEndDataOut ? frontEndDataOut->commands : nullptr;
}

// Lay a string out the way RB_DrawText2D does: each glyph is offset by x0,y0 from
// the pen, drawn at pixelWidth x pixelHeight, and the pen advances by dx - all in
// units of the command's scale. The glyph's own s0..t1 index the font's atlas.
// Draw with the built-in 8x8 font. Crude, but every glyph is the right glyph.
void DrawTextFallback(const GfxCmdDrawText2D *cmd)
{
    const float charW = 8.0f * cmd->xScale;
    const float charH = 8.0f * cmd->yScale;
    gfx_gl::draw_ui_text(cmd->x, cmd->y - charH, cmd->text, charW, charH,
                         cmd->color.array[0] / 255.0f,
                         cmd->color.array[1] / 255.0f,
                         cmd->color.array[2] / 255.0f,
                         cmd->color.array[3] / 255.0f);
}

void DrawText(const GfxCmdDrawText2D *cmd)
{
    const unsigned int atlas = TextureForMaterial(cmd->font->material);
    if (!atlas)
    {
        DrawTextFallback(cmd);
        return;
    }

    static bool traced = false;
    if (!traced && std::getenv("KISAK_TEXT_TRACE"))
    {
        traced = true;
        const Material *fm = cmd->font->material;
        std::printf("[text] font='%s' pixelHeight=%d glyphs=%d xScale=%.2f yScale=%.2f text='%.24s'\n",
                    cmd->font->fontName ? cmd->font->fontName : "?",
                    cmd->font->pixelHeight, cmd->font->glyphCount, cmd->xScale, cmd->yScale, cmd->text);
        std::printf("[text] material='%s' textureCount=%d\n",
                    fm && fm->info.name ? fm->info.name : "?", fm ? fm->textureCount : -1);
        for (int i = 0; fm && i < fm->textureCount; ++i)
        {
            const GfxImage *im = fm->textureTable[i].u.image;
            const GfxImageLoadDef *ld = im ? im->texture.loadDef : nullptr;
            const unsigned fcc = ld ? static_cast<unsigned>(ld->format) : 0;
            char tag[5] = {0};
            for (int k = 0; k < 4; ++k) { const char ch = static_cast<char>((fcc >> (8*k)) & 0xFF); tag[k] = (ch >= 32 && ch < 127) ? ch : '.'; }
            std::printf("[text]   tex[%d] semantic=%u image='%s' %ux%u fmt=%u '%s' resourceSize=%d\n", i,
                        fm->textureTable[i].semantic, im && im->name ? im->name : "?",
                        im ? im->width : 0, im ? im->height : 0, fcc, tag, ld ? ld->resourceSize : -1);
        }
        for (unsigned c = 'A'; c <= 'C'; ++c)
        {
            const Glyph *gl = R_GetCharacterGlyph(cmd->font, c);
            if (gl)
                std::printf("[text]   '%c' letter=%u x0=%d y0=%d dx=%u w=%u h=%u uv=(%.4f,%.4f)-(%.4f,%.4f)\n",
                            c, gl->letter, gl->x0, gl->y0, gl->dx, gl->pixelWidth, gl->pixelHeight,
                            gl->s0, gl->t0, gl->s1, gl->t1);
        }
        std::fflush(stdout);
    }

    const float baseR = cmd->color.array[0] / 255.0f;
    const float baseG = cmd->color.array[1] / 255.0f;
    const float baseB = cmd->color.array[2] / 255.0f;
    const float a = cmd->color.array[3] / 255.0f;
    float r = baseR;
    float g = baseG;
    float b = baseB;

    float penX = cmd->x - 0.5f * cmd->xScale;
    const float penY = cmd->y - 0.5f * cmd->yScale;

    const char *text = cmd->text;
    for (int drawn = 0; *text && drawn < cmd->maxChars;)
    {
        if (text[0] == '^' && text[1] >= '0' && text[1] <= '9')
        {
            if (text[1] == '7')
            {
                r = baseR;
                g = baseG;
                b = baseB;
            }
            else
            {
                GfxColor inlineColor{};
                RB_LookupColor(static_cast<unsigned char>(text[1]), &inlineColor);
                r = inlineColor.array[0] / 255.0f;
                g = inlineColor.array[1] / 255.0f;
                b = inlineColor.array[2] / 255.0f;
            }
            text += 2;
            continue;
        }

        const unsigned char letter = static_cast<unsigned char>(*text++);
        ++drawn;
        const Glyph *glyph = R_GetCharacterGlyph(cmd->font, letter);
        if (!glyph)
            continue;

        static int shown = 0;
        if (shown < 6 && std::getenv("KISAK_TEXT_TRACE"))
        {
            ++shown;
            std::printf("[draw] '%c' quad=(%.1f,%.1f %.1fx%.1f) uv=(%.4f,%.4f)-(%.4f,%.4f) tex=%u\n",
                        letter, penX + glyph->x0 * cmd->xScale, penY + glyph->y0 * cmd->yScale,
                        glyph->pixelWidth * cmd->xScale, glyph->pixelHeight * cmd->yScale,
                        glyph->s0, glyph->t0, glyph->s1, glyph->t1, atlas);
            std::fflush(stdout);
        }

        if (glyph->pixelWidth && glyph->pixelHeight)
        {
            gfx_gl::draw_ui_textured_rect(penX + glyph->x0 * cmd->xScale,
                                          penY + glyph->y0 * cmd->yScale,
                                          glyph->pixelWidth * cmd->xScale,
                                          glyph->pixelHeight * cmd->yScale,
                                          glyph->s0, glyph->t0, glyph->s1, glyph->t1,
                                          atlas, r, g, b, a);
        }

        penX += glyph->dx * cmd->xScale;
    }
}

void DispatchCommands(const GfxCmdArray *list)
{
    if (!list || !list->cmds || list->usedTotal <= 0)
        return;

    size_t pos = 0;
    while (pos < static_cast<size_t>(list->usedTotal))
    {
        const auto *hdr = reinterpret_cast<const GfxCmdHeader *>(list->cmds + pos);
        if (hdr->id == RC_END_OF_LIST || hdr->byteCount == 0)
            break;

        switch (hdr->id)
        {
        case RC_CLEAR_SCREEN:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdClearScreen *>(hdr);
            gfx_gl::clear_now(cmd->color[0], cmd->color[1], cmd->color[2], cmd->color[3]);
            break;
        }
        case RC_STRETCH_PIC:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdStretchPic *>(hdr);
            const float r = cmd->color.array[0] / 255.0f;
            const float g = cmd->color.array[1] / 255.0f;
            const float b = cmd->color.array[2] / 255.0f;
            const float a = cmd->color.array[3] / 255.0f;

            // The command's colour modulates the material. Untextured materials -
            // solid panels and fills - keep their flat quad.
            const unsigned int texture = TextureForMaterial(cmd->material);
            if (texture)
            {
                gfx_gl::draw_ui_textured_rect(cmd->x, cmd->y, cmd->w, cmd->h,
                                              cmd->s0, cmd->t0, cmd->s1, cmd->t1,
                                              texture, r, g, b, a);
            }
            else if (!MaterialWantsTexture(cmd->material))
            {
                gfx_gl::draw_ui_filled_rect(cmd->x, cmd->y, cmd->w, cmd->h, r, g, b, a);
            }
            // A material that wants a colour map we could not load draws nothing. The
            // flat quad would be a solid block of the modulation colour - the logo came
            // out as a white rectangle - which reads as a defect rather than a gap.
            break;
        }
        case RC_DRAW_TEXT_2D:
        {
            const auto *cmd = reinterpret_cast<const GfxCmdDrawText2D *>(hdr);
            // text[] is declared short; the engine sizes the command to hold the
            // whole null-terminated string past the end of the array.
            if (cmd->maxChars > 0 && cmd->font)
                DrawText(cmd);
            break;
        }
        default:
            // Everything else is 3D or needs textures. Skipping keeps the walk
            // going instead of stalling on the first opcode we cannot express.
            break;
        }

        pos += hdr->byteCount;
    }
}

} // namespace

bool CreateWindow(const int width, const int height)
{
#ifdef KISAK_DXVK
    // DXVK puts a Metal surface on this window, which cannot share it with a GL
    // context, so under DXVK the window is created plain and gfx_gl never runs.
    g_window = SDL_CreateWindow("jgalbs cod4", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                width, height, SDL_WINDOW_SHOWN | SDL_WINDOW_ALLOW_HIGHDPI
                                    | SDL_WINDOW_RESIZABLE);
    if (!g_window)
    {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        return false;
    }

    UpdateDisplayFrequency();
    return true;
#else
    // gfx_gl's shaders are written for OpenGL 2.1 Compatibility - "attribute",
    // "varying" and no #version directive, which is GLSL 110. A 3.2 Core context
    // rejects them outright ("#version required and missing"). 2.1 is the other
    // profile macOS offers and the one those shaders were written against.
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_COMPATIBILITY);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);

    g_window = SDL_CreateWindow("jgalbs cod4", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                width, height, SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN
                                    | SDL_WINDOW_ALLOW_HIGHDPI | SDL_WINDOW_RESIZABLE);
    if (!g_window)
    {
        std::fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        return false;
    }

    g_context = SDL_GL_CreateContext(g_window);
    if (!g_context)
    {
        std::fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        return false;
    }

    // Hand it off: a context can only be current on one thread, and the engine
    // thread is the one that draws.
    SDL_GL_MakeCurrent(g_window, nullptr);
    UpdateDisplayFrequency();
    return true;
#endif // KISAK_DXVK
}

SDL_Window *Window()
{
    return g_window;
}

bool AdoptContext()
{
#ifdef KISAK_DXVK
    // Nothing to adopt: D3D9 has no thread-bound context to hand over, and the
    // device is created by the renderer rather than here.
    return g_window != nullptr;
#else
    if (!g_window || !g_context)
        return false;

    if (SDL_GL_MakeCurrent(g_window, g_context) != 0)
    {
        std::fprintf(stderr, "SDL_GL_MakeCurrent on the engine thread failed: %s\n", SDL_GetError());
        return false;
    }

    // Off until the dvars exist; PresentFrame follows r_vsync from then on.
    SDL_GL_SetSwapInterval(0);

    if (!gfx_gl::init())
    {
        std::fprintf(stderr, "gfx_gl::init failed\n");
        return false;
    }

    int w = 0;
    int h = 0;
    SDL_GL_GetDrawableSize(g_window, &w, &h);
    gfx_gl::set_viewport(w, h);

    g_ready = true;
    std::printf("[gl] context adopted on the engine thread, drawable %dx%d\n", w, h);
    std::fflush(stdout);
    return true;
#endif // KISAK_DXVK
}

namespace {

// Read the backbuffer straight out of GL and write a PPM. Screen capture would
// depend on window stacking and would photograph whatever else is on the display;
// this shows exactly what the engine drew and nothing else.
void DumpBackbuffer(const char *path)
{
    int w = 0;
    int h = 0;
    SDL_GL_GetDrawableSize(g_window, &w, &h);
    if (w <= 0 || h <= 0)
        return;

    std::vector<unsigned char> pixels(static_cast<size_t>(w) * h * 3);
    glReadPixels(0, 0, w, h, GL_RGB, GL_UNSIGNED_BYTE, pixels.data());

    std::FILE *f = std::fopen(path, "wb");
    if (!f)
        return;

    std::fprintf(f, "P6\n%d %d\n255\n", w, h);
    // glReadPixels starts at the bottom-left; PPM rows run top-down.
    for (int y = h - 1; y >= 0; --y)
        std::fwrite(pixels.data() + static_cast<size_t>(y) * w * 3, 1, static_cast<size_t>(w) * 3, f);
    std::fclose(f);

    std::printf("[gl] wrote %s (%dx%d)\n", path, w, h);
    std::fflush(stdout);
}

bool g_dumpRequested;
int g_dumpCount;

} // namespace

void RequestFrameDump()
{
    g_dumpRequested = true;
}

void PresentFrame()
{
    if (!g_ready)
        return;

    int drawableWidth = 0;
    int drawableHeight = 0;
    SDL_GL_GetDrawableSize(g_window, &drawableWidth, &drawableHeight);
    if (drawableWidth > 0 && drawableHeight > 0)
        gfx_gl::set_viewport(drawableWidth, drawableHeight);

    DispatchCommands(CurrentCommands());
    gfx_gl::flush_ui();

    static int frame = 0;
    ++frame;

    // KISAK_AUTOTYPE drives the menus for a headless check: once the UI has settled,
    // type the string a character at a time, then press Enter.
    const char *autotype = std::getenv("KISAK_AUTOTYPE");
    if (autotype)
    {
        const int start = 90;
        const int length = static_cast<int>(std::strlen(autotype));
        if (frame >= start && frame < start + length)
        {
            posix_input::InjectChar(static_cast<unsigned char>(autotype[frame - start]));
        }
        else if (frame == start + length + 10)
        {
            posix_input::InjectKey(K_ENTER, true);
        }
        else if (frame == start + length + 12)
        {
            posix_input::InjectKey(K_ENTER, false);
        }
    }

    // KISAK_AUTOCLICK is a semicolon separated list of "x,y,frame" - move the cursor
    // there and click, so a whole path through the menus can be replayed.
    const char *autoclick = std::getenv("KISAK_AUTOCLICK");
    for (const char *step = autoclick; step && *step; )
    {
        int cx = 0, cy = 0, at = 0;
        if (std::sscanf(step, "%d,%d,%d", &cx, &cy, &at) == 3)
        {
            if (frame >= at - 4 && frame <= at + 4)
                posix_input::InjectCursor(cx, cy);
            if (frame == at)
                posix_input::InjectKey(K_MOUSE1, true);
            if (frame == at + 2)
                posix_input::InjectKey(K_MOUSE1, false);
        }
        const char *next = std::strchr(step, ';');
        step = next ? next + 1 : nullptr;
    }

    // Two frame limiters fight each other, so only one of them may be active: with
    // vsync on, com_maxfps has to sit above the refresh rate or the engine's own wait
    // in R_WaitEndTime lands frames off the refresh boundary and they judder. Presenting
    // uncapped is worse - 91 fps into a 100 Hz display beats at 9 Hz whatever the frame
    // times look like - so vsync wins and the cap is lifted out of its way.
    if (r_vsync)
    {
        static int applied = -1;
        const int wanted = r_vsync->current.enabled ? 1 : 0;
        if (wanted != applied)
        {
            applied = wanted;
            SDL_GL_SetSwapInterval(wanted);
            if (wanted && com_maxfps && com_maxfps->current.integer)
                Dvar_SetIntByName("com_maxfps", 0);
        }
    }

    if (g_dumpRequested)
    {
        g_dumpRequested = false;
        char path[MAX_OSPATH];
        Com_sprintf(path, sizeof(path), "%s/screenshots/shot%04d.ppm",
                    fs_basepath->current.string, g_dumpCount++);
        FS_CreatePath(path);
        DumpBackbuffer(path);
    }

    const char *dumpPath = std::getenv("KISAK_GL_DUMP");
    const char *dumpFrameEnv = std::getenv("KISAK_GL_DUMP_FRAME");
    const int dumpFrame = dumpFrameEnv ? std::atoi(dumpFrameEnv) : 120;
    // Then once a second or so, overwriting: a run that is watching for something to
    // appear in-game cannot know in advance which frame to ask for, and the frame
    // count depends on how long the map took to load.
    const char *dumpEveryEnv = std::getenv("KISAK_GL_DUMP_EVERY");
    const int dumpEvery = dumpEveryEnv ? std::atoi(dumpEveryEnv) : 0;
    if (dumpPath && frame >= dumpFrame
        && (frame == dumpFrame || (dumpEvery > 0 && (frame - dumpFrame) % dumpEvery == 0)))
    {
        DumpBackbuffer(dumpPath);
    }

    SDL_GL_SwapWindow(g_window);

    if (std::getenv("KISAK_FPS"))
    {
        static Uint64 last = 0;
        static double worst = 0.0;
        static double total = 0.0;
        static int counted = 0;
        const Uint64 now = SDL_GetPerformanceCounter();
        if (last)
        {
            const double ms = 1000.0 * static_cast<double>(now - last) / static_cast<double>(SDL_GetPerformanceFrequency());
            total += ms;
            worst = ms > worst ? ms : worst;
            if (++counted == 120)
            {
                std::printf("[fps] avg %.2f ms (%.0f fps)  worst %.2f ms\n", total / counted, 1000.0 * counted / total, worst);
                std::fflush(stdout);
                total = 0.0; worst = 0.0; counted = 0;
            }
        }
        last = now;
    }
}

bool HasWindow()
{
    return g_window != nullptr;
}

int DisplayFrequency()
{
    return g_displayFrequency;
}

void WindowSize(int *width, int *height)
{
    int w = 0;
    int h = 0;
    if (g_window)
        SDL_GetWindowSize(g_window, &w, &h);
    if (width)
        *width = w;
    if (height)
        *height = h;
}

void RequestWindowSize(const int width, const int height)
{
    if (width < 640 || height < 480)
        return;
    const auto packed = (static_cast<unsigned long long>(static_cast<unsigned int>(width)) << 32)
        | static_cast<unsigned int>(height);
    g_requestedWindowSize.store(packed, std::memory_order_release);
}

void RequestWindowFullscreen(const bool fullscreen)
{
    g_requestedFullscreen.store(fullscreen ? 1 : 0, std::memory_order_release);
}

void UpdateWindowMainThread()
{
    if (!g_window)
        return;

    const int requestedFullscreen = g_requestedFullscreen.exchange(
        -1, std::memory_order_acq_rel);
    if (requestedFullscreen >= 0)
    {
        const Uint32 flags = requestedFullscreen ? SDL_WINDOW_FULLSCREEN_DESKTOP : 0;
        if (SDL_SetWindowFullscreen(g_window, flags) != 0)
            std::fprintf(stderr, "SDL_SetWindowFullscreen failed: %s\n", SDL_GetError());
    }

    if ((SDL_GetWindowFlags(g_window) & SDL_WINDOW_FULLSCREEN) != 0)
        return;
    const auto packed = g_requestedWindowSize.exchange(0, std::memory_order_acq_rel);
    if (!packed)
        return;
    const int width = static_cast<int>(packed >> 32);
    const int height = static_cast<int>(packed & 0xffffffffu);
    SDL_SetWindowSize(g_window, width, height);
}

void DrawableSize(int *width, int *height)
{
    int w = 0;
    int h = 0;
    if (g_window)
        SDL_GL_GetDrawableSize(g_window, &w, &h);
    if (width)
        *width = w;
    if (height)
        *height = h;
}

} // namespace posix_gl
