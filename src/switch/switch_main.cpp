// Entry point Switch homebrew (libnx + EGL).
//
// Responsavel pelo bootstrap do hardware (libnx, HID), criacao do contexto
// GL via EGL e loop principal. A renderizacao em si fica em src/gfx_gl/
// (gl_renderer), agnostica de windowing — vai ser reutilizada pelo build
// POSIX desktop quando ele existir.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

#include <switch.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <malloc.h>

#include "gfx_gl/gl_renderer.h"
#include "qcommon/qcommon.h"
#include "client_mp/client_mp.h"
#include "ui/ui_shared.h"

// libnx's default heap is tiny (newlib reports ~116 KiB arena). For
// the CoD4 NO_FASTFILES path we need an actual budget — the menu
// parser alone allocates 4 KiB blocks that fail on the default heap.
// Override the weak `__nx_heap_size` global with 64 MiB; that's well
// under any reasonable Switch applet quota so svcSetHeapSize won't
// fail the init, but plenty for the boot-time GetMemory/Z_Malloc
// traffic the engine emits.
extern "C" {
    __attribute__((used, visibility("default")))
    size_t __nx_heap_size = 0x18000000;  // 384 MiB
}

namespace {

EGLDisplay g_display = EGL_NO_DISPLAY;
EGLContext g_context = EGL_NO_CONTEXT;
EGLSurface g_surface = EGL_NO_SURFACE;

bool egl_init(NWindow *win)
{
    g_display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_display == EGL_NO_DISPLAY) {
        std::fprintf(stderr, "eglGetDisplay falhou: %d\n", eglGetError());
        return false;
    }

    eglInitialize(g_display, nullptr, nullptr);

    if (eglBindAPI(EGL_OPENGL_ES_API) == EGL_FALSE) {
        std::fprintf(stderr, "eglBindAPI(ES) falhou: %d\n", eglGetError());
        eglTerminate(g_display);
        g_display = EGL_NO_DISPLAY;
        return false;
    }

    static const EGLint cfg_attrs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE,    8,
        EGL_GREEN_SIZE,  8,
        EGL_BLUE_SIZE,   8,
        EGL_ALPHA_SIZE,  8,
        EGL_DEPTH_SIZE, 24,
        EGL_NONE,
    };
    EGLConfig config;
    EGLint num_configs = 0;
    eglChooseConfig(g_display, cfg_attrs, &config, 1, &num_configs);
    if (num_configs == 0) {
        std::fprintf(stderr, "eglChooseConfig falhou\n");
        eglTerminate(g_display);
        return false;
    }

    g_surface = eglCreateWindowSurface(g_display, config, win, nullptr);
    if (g_surface == EGL_NO_SURFACE) {
        std::fprintf(stderr, "eglCreateWindowSurface falhou: %d\n", eglGetError());
        eglTerminate(g_display);
        return false;
    }

    static const EGLint ctx_attrs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };
    g_context = eglCreateContext(g_display, config, EGL_NO_CONTEXT, ctx_attrs);
    if (g_context == EGL_NO_CONTEXT) {
        std::fprintf(stderr, "eglCreateContext falhou: %d\n", eglGetError());
        eglDestroySurface(g_display, g_surface);
        eglTerminate(g_display);
        return false;
    }

    eglMakeCurrent(g_display, g_surface, g_surface, g_context);
    return true;
}

void egl_shutdown()
{
    if (g_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(g_display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (g_context != EGL_NO_CONTEXT) {
            eglDestroyContext(g_display, g_context);
        }
        if (g_surface != EGL_NO_SURFACE) {
            eglDestroySurface(g_display, g_surface);
        }
        eglTerminate(g_display);
    }
}

// Route Sys_Print (the upstream CoD4 console output sink) to the Switch
// debug log. On Ryujinx this surfaces as `Application LogInfo: ...` lines,
// which is the only way we can see Com_Printf / Com_PrintError during
// Com_Init when no console framebuffer is attached.
void switch_debug_log(const char *msg)
{
    if (!msg) return;
    svcOutputDebugString(msg, std::strlen(msg));
}

} // namespace

void Sys_Print(const char *msg)
{
    switch_debug_log(msg);
}

int main(int /*argc*/, char ** /*argv*/)
{
    {
        // Probe newlib's view of the heap. mallinfo() reports the size
        // of the dlmalloc-managed arena (what's been touched so far).
        struct mallinfo mi = mallinfo();
        // Direct check of fake_heap_start/end (libnx-supplied newlib
        // heap region) so we can tell whether our __nx_heap_size
        // override actually landed.
        extern char *fake_heap_start;
        extern char *fake_heap_end;
        char dbg[256];
        std::snprintf(dbg, sizeof(dbg),
                      "[switch_main] heap_start=%p heap_end=%p span=%zu (%zu MiB) mallinfo arena=%zu",
                      (void *)fake_heap_start, (void *)fake_heap_end,
                      (size_t)(fake_heap_end - fake_heap_start),
                      (size_t)((fake_heap_end - fake_heap_start) >> 20),
                      (size_t)mi.arena);
        svcOutputDebugString(dbg, std::strlen(dbg));
    }

    NWindow *win = nwindowGetDefault();
    if (!egl_init(win)) {
        return EXIT_FAILURE;
    }

    if (!gfx_gl::init()) {
        egl_shutdown();
        return EXIT_FAILURE;
    }
    gfx_gl::set_viewport(1280, 720);

    // Upstream's D3D9 init populates cls.vidConfig when the device is
    // created; on Switch our renderer is separate so we seed it before
    // Com_Init runs the client side, which asserts displayWidth > 0.
    cls.vidConfig.sceneWidth = 1280;
    cls.vidConfig.sceneHeight = 720;
    cls.vidConfig.displayWidth = 1280;
    cls.vidConfig.displayHeight = 720;
    cls.vidConfig.displayFrequency = 60;
    cls.vidConfig.isFullscreen = 1;
    cls.vidConfig.aspectRatioWindow = 16.0f / 9.0f;
    cls.vidConfig.aspectRatioScenePixel = 1.0f;
    cls.vidConfig.aspectRatioDisplayPixel = 1.0f;
    cls.vidConfig.maxTextureSize = 4096;
    cls.vidConfig.maxTextureMaps = 8;
    cls.vidConfig.deviceSupportsGamma = false;

    PadState pad;
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&pad);

    // Anchor the engine FS root at sdmc:/switch/cod4/ so CoD4's relative
    // paths (./main/iw_00.iwd, ./zone/english/*.ff, ...) resolve into the
    // game assets we drop alongside the NRO on the SD card.
    if (chdir("sdmc:/switch/cod4") != 0) {
        switch_debug_log("[switch_main] chdir(sdmc:/switch/cod4) failed\n");
    } else {
        switch_debug_log("[switch_main] chdir(sdmc:/switch/cod4) OK\n");
    }

    switch_debug_log("[switch_main] before Com_InitThreadData\n");
    // Bring up the CoD4 engine. Com_InitThreadData(0) seeds the main thread's
    // TLS slots (jmp_buf at slot 2, va rotating buffer at slot 1) which
    // Com_Init dereferences immediately via Sys_GetValue(2). Upstream this
    // happens inside Sys_InitMainThread() — that one is Win32-only, so we
    // call the cross-platform half directly.
    Com_InitThreadData(0);
    switch_debug_log("[switch_main] after Com_InitThreadData, calling Com_Init\n");

    // Com_Init pulls in FS, dvars, hunk alloc, localization, etc. If iwd
    // assets are missing this raises Sys_Error and exits; the demo cube
    // path below is only reached when init returns.
    char cmdline[1] = {0};
    Com_Init(cmdline);
    extern void switch_reset_render_queue();
    extern void switch_dispatch_render_queue();

    switch_debug_log("[switch_main] Com_Init returned, entering Com_Frame loop\n");

    // Inspeciona os fastfiles de UI pra a gente saber a populacao de
    // assets que precisa decodificar. So leitura — nao registra nada
    // ainda; e a base do pipeline incremental.
    extern void switch_inspect_zone(const char *path);
    // SP focus: catalog the assets we need to support for the first
    // single-player mission to render. ac130 is a good start because it
    // is gunship-only (no player movement, no AI complex) — minimal
    // surface area to debug rendering. Then bog_a is the standard
    // infantry mission. ui.ff replaces ui_mp.ff for SP menus.
    switch_inspect_zone("zone/english/ui.ff");
    switch_inspect_zone("zone/english/common.ff");
    switch_inspect_zone("zone/english/ac130.ff");
    switch_inspect_zone("zone/english/bog_a.ff");
    switch_inspect_zone("zone/english/airlift.ff");
    switch_inspect_zone("zone/english/coup.ff");
    switch_inspect_zone("zone/english/hunted.ff");

    // Primeiro passo do binary fastfile loader: open + inflate via
    // nosso DB_LoadXFileData redirecionado, le o XFile + XAssetList
    // header. Proximas sessoes adicionam per-asset decoders.
    extern int switch_load_zone(const char *zone_name, const char *path);
    switch_load_zone("ui", "zone/english/ui.ff");

    // Kick the UI subsystem into UIMENU_MAIN — the engine doesn't open
    // anything automatically at boot in MP, so without this push our
    // loaded menu file (renamed to "main") never gets onto the active
    // stack and the render queue keeps emitting only the baseline 3
    // opcodes.
    extern int UI_SetActiveMenu(int localClientNum, uiMenuCommand_t menu);
    UI_SetActiveMenu(0, UIMENU_MAIN);
    switch_debug_log("[switch_main] UI_SetActiveMenu(UIMENU_MAIN) called\n");

    // CL_KeyEvent feeds CoD4's input layer. Para o usuario ver o menu
    // responder, mapeamos os botoes do JoyCon pros key codes que a UI
    // do CoD4 espera (UPARROW/DOWNARROW/ENTER/ESCAPE/etc).
    extern void __cdecl CL_KeyEvent(int32_t localClientNum, int32_t key, int32_t down, uint32_t time);
    struct ButtonMap { uint64_t hid; int key; const char *name; };
    static const ButtonMap kKeyMap[] = {
        { HidNpadButton_Up,    0x9A, "UP" },     // K_UPARROW
        { HidNpadButton_Down,  0x9B, "DOWN" },   // K_DOWNARROW
        { HidNpadButton_Left,  0x9C, "LEFT" },   // K_LEFTARROW
        { HidNpadButton_Right, 0x9D, "RIGHT" },  // K_RIGHTARROW
        { HidNpadButton_A,     0x0D, "A=ENTER" },// K_ENTER (CoD4 select)
        { HidNpadButton_B,     0x1B, "B=ESC" },  // K_ESCAPE
        { HidNpadButton_Y,     0x20, "Y=SPACE" },// K_SPACE
        { HidNpadButton_X,     0x09, "X=TAB" },  // K_TAB
    };

    int frame = 0;
    while (appletMainLoop()) {
        switch_reset_render_queue();
        padUpdate(&pad);
        const uint64_t down = padGetButtonsDown(&pad);
        const uint64_t up   = padGetButtonsUp(&pad);
        if (down & HidNpadButton_Plus) {
            break;
        }
        // Translate edges to key events.
        for (const auto &m : kKeyMap) {
            if (down & m.hid) {
                CL_KeyEvent(0, m.key, 1, (unsigned)frame);
                char dbg[64];
                std::snprintf(dbg, sizeof(dbg), "[input] %s down -> key %d\n", m.name, m.key);
                switch_debug_log(dbg);
            }
            if (up & m.hid) {
                CL_KeyEvent(0, m.key, 0, (unsigned)frame);
            }
        }

        if (frame < 5) {
            char dbg[64];
            std::snprintf(dbg, sizeof(dbg), "[switch_main] Com_Frame begin #%d\n", frame);
            switch_debug_log(dbg);
        }
        Com_Frame();
        if (frame < 5) {
            char dbg[64];
            std::snprintf(dbg, sizeof(dbg), "[switch_main] Com_Frame end #%d\n", frame);
            switch_debug_log(dbg);
        }
        ++frame;

        // Apply CoD4's render queue. The dispatcher does its own glClear
        // when it sees RC_CLEAR_SCREEN, so any draws it issues afterwards
        // survive. We do NOT glClear again before swap or we'd wipe them.
        switch_dispatch_render_queue();
        eglSwapBuffers(g_display, g_surface);
    }

    gfx_gl::shutdown();
    egl_shutdown();
    return EXIT_SUCCESS;
}
