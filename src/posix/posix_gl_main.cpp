// POSIX/macOS entry point.
//
// This used to be a standalone GL sandbox: it opened an SDL window and drove
// gfx_gl::render_frame() in a loop, which was useful for iterating shaders but
// never started the engine. All ~350 engine translation units were linked in and
// simply never ran. This boots the engine instead, mirroring the bootstrap in
// src/win32/win_main.cpp:786-846.
//
// THREADING. AppKit owns the main thread on macOS: NSWindow can only be created
// there, and a cross-thread dispatch_sync onto the main queue - which is what
// SDL's Cocoa GL path does - is serviced only by NSApp's own event loop. The
// engine assumes it owns the main thread and blocks in Com_Frame forever, so the
// two models cannot both hold. Every macOS game port resolves this the same way,
// and it is what SDL_main does for you: run the game on a secondary thread and
// leave the real main thread to Cocoa.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <execinfo.h>
#include <iterator>
#include <pthread.h>
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
#include <unistd.h>

#include <SDL.h>

#include "gfx_gl/gl_renderer.h"
#include "posix/posix_gl_present.h"
#include "posix/posix_input.h"
#if defined(__APPLE__) && defined(KISAK_SPARKLE_UPDATER)
#include "posix/posix_updater.h"
#endif
#include "client_mp/client_mp.h"   // cls.vidConfig
#include "ui/ui_shared.h"

// Engine bootstrap, in the order win_main.cpp:794-846 calls them. Include the real
// headers rather than re-declaring: these are C++ symbols, and an extern "C" block
// gives them the wrong linkage.
#include "universal/q_shared.h"
#include "universal/q_parse.h"
#include "qcommon/qcommon.h"

extern "C" void Posix_FindSysInfo();

namespace {

constexpr int kWindowW = 1280;
constexpr int kWindowH = 720;

char g_cmdline[1024] = "";

bool HasCommandLineDvar(const char *name)
{
    return name && *name && std::strstr(g_cmdline, name) != nullptr;
}

bool IsGameDataDirectory(const char *path)
{
    if (!path || !*path)
        return false;
    char sentinel[1024];
    const int length = std::snprintf(sentinel, sizeof(sentinel), "%s/main/iw_00.iwd", path);
    return length > 0 && static_cast<size_t>(length) < sizeof(sentinel)
        && access(sentinel, R_OK) == 0;
}

void AppendCommandLineText(const char *text)
{
    if (!text || !*text)
        return;
    const size_t oldLength = std::strlen(g_cmdline);
    const size_t textLength = std::strlen(text);
    if (oldLength + textLength + (oldLength ? 2u : 1u) >= sizeof(g_cmdline))
        return;
    if (oldLength)
        std::strcat(g_cmdline, " ");
    std::strcat(g_cmdline, text);
}

void AddDefaultGameDataArguments()
{
    if (HasCommandLineDvar("fs_basepath"))
        return;

    const char *dataPath = std::getenv("COD4_DATA_PATH");
    char savedCandidate[1024]{};
    char homeCandidate[1024]{};
    if (!IsGameDataDirectory(dataPath)
#if defined(__APPLE__) && defined(KISAK_METAL)
        && posix_gl::SavedGameDataDirectory(savedCandidate, sizeof(savedCandidate))
#else
        && false
#endif
        && IsGameDataDirectory(savedCandidate))
    {
        dataPath = savedCandidate;
    }
    if (!IsGameDataDirectory(dataPath))
    {
        const char *const userHome = std::getenv("HOME");
        if (userHome && *userHome)
        {
            const int length = std::snprintf(homeCandidate, sizeof(homeCandidate),
                                             "%s/Games/cod4", userHome);
            if (length > 0 && static_cast<size_t>(length) < sizeof(homeCandidate)
                && IsGameDataDirectory(homeCandidate))
            {
                dataPath = homeCandidate;
            }
        }
    }
    if (!IsGameDataDirectory(dataPath))
    {
        static char workingDirectory[1024];
        if (getcwd(workingDirectory, sizeof(workingDirectory))
            && IsGameDataDirectory(workingDirectory))
        {
            dataPath = workingDirectory;
        }
    }
    if (!IsGameDataDirectory(dataPath))
    {
#if defined(__APPLE__) && defined(KISAK_METAL)
        if (posix_gl::SelectGameDataDirectory(savedCandidate, sizeof(savedCandidate))
            && IsGameDataDirectory(savedCandidate))
        {
            dataPath = savedCandidate;
        }
#endif
    }
    if (!IsGameDataDirectory(dataPath))
        return;

    const char *homePath = dataPath;
    char writableCandidate[1024]{};
#if defined(__APPLE__) && defined(KISAK_METAL)
    if (posix_gl::WritableGameDataDirectory(writableCandidate, sizeof(writableCandidate)))
        homePath = writableCandidate;
#endif

    char arguments[2048];
    const int length = std::snprintf(arguments, sizeof(arguments),
        "+set fs_basepath \"%s\" +set fs_homepath \"%s\"", dataPath, homePath);
    if (length > 0 && static_cast<size_t>(length) < sizeof(arguments))
    {
        AppendCommandLineText(arguments);
        std::printf("Using CoD4 data from %s (writable data: %s)\n", dataPath, homePath);
    }
}

void CrashSignalHandler(const int signalNumber, siginfo_t *, void *)
{
    static constexpr char message[] =
        "\n[posix-crash] fatal signal; native backtrace follows\n";
    (void)::write(STDERR_FILENO, message, sizeof(message) - 1);
    void *frames[96]{};
    const int frameCount = ::backtrace(frames, static_cast<int>(std::size(frames)));
    ::backtrace_symbols_fd(frames, frameCount, STDERR_FILENO);
    // SA_RESETHAND restores the default disposition before this handler runs.
    // Re-raise so macOS still produces its normal crash report and exit status.
    (void)::kill(::getpid(), signalNumber);
    _exit(128 + signalNumber);
}

void InstallCrashHandlers()
{
    struct sigaction action{};
    action.sa_sigaction = CrashSignalHandler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO | SA_RESETHAND;
    constexpr int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT};
    for (const int signalNumber : signals)
        (void)sigaction(signalNumber, &action, nullptr);
}

void *engine_thread(void *)
{
#if defined(__APPLE__)
    // The game thread drives input, networking, simulation, audio submission,
    // and Metal command encoding.  Keep that latency-sensitive work on the
    // interactive QoS tier even when another game window has focus (for local
    // multiplayer testing and listen-server hosting).
    (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    // The engine's own idea of "main" is this thread; the OS main thread is Cocoa's.
    //
    // Com_InitThreadData installs the per-thread va buffer, the trace info and - the one
    // that matters here - the jmp_buf that Com_Init longjmps back to on a fatal error.
    // Com_Init does `_setjmp(*(jmp_buf *)Sys_GetValue(2))` (common.cpp:1084) and the slot
    // is pthread-local, so without this call on THIS thread it dereferences null. On
    // Windows threads.cpp does it as part of thread registration; that file is not ported.
    Com_InitThreadData(0);
    Posix_FindSysInfo();
    posix_gl::AdoptContext();          // Windows does this in Sys_FindInfo() before Com_Init

    // Upstream's D3D9 init fills cls.vidConfig when it creates the device. gfx_gl is a
    // separate renderer, so seed it here or CL_InitRenderer asserts on
    // cls.vidConfig.displayWidth > 0 (screen_placement.cpp:53). Same values and the same
    // reasoning as the Switch entry point, src/switch/switch_main.cpp:167-178.
    cls.vidConfig.sceneWidth              = kWindowW;
    cls.vidConfig.sceneHeight             = kWindowH;
    cls.vidConfig.displayWidth            = kWindowW;
    cls.vidConfig.displayHeight           = kWindowH;
    cls.vidConfig.displayFrequency        = posix_gl::DisplayFrequency();
    cls.vidConfig.isFullscreen            = 0;
    cls.vidConfig.aspectRatioWindow       = float(kWindowW) / float(kWindowH);
    cls.vidConfig.aspectRatioScenePixel   = 1.0f;
    cls.vidConfig.aspectRatioDisplayPixel = 1.0f;
    cls.vidConfig.maxTextureSize          = 4096;
    cls.vidConfig.maxTextureMaps          = 8;
    cls.vidConfig.deviceSupportsGamma     = false;

    Com_InitParse();
    Dvar_Init();
    Sys_Milliseconds();          // seeds the timer base
    Com_Init(g_cmdline);

    for (;;) {
        Com_Frame();
    }
    return nullptr;
}

} // namespace

int main(int argc, char **argv)
{
    InstallCrashHandlers();
    for (int i = 1; i < argc; ++i) {
        if (std::strlen(g_cmdline) + std::strlen(argv[i]) + 2 >= sizeof(g_cmdline)) break;
        if (g_cmdline[0]) std::strcat(g_cmdline, " ");
        std::strcat(g_cmdline, argv[i]);
    }
    AddDefaultGameDataArguments();
    std::printf("jgalbs cod4 native/arm64 starting  cmdline: '%s'\n", g_cmdline);
    std::fflush(stdout);

    // Video comes up on the main thread so the window server connection is owned here.
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS | SDL_INIT_AUDIO) != 0) {
        std::fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return EXIT_FAILURE;
    }
    std::printf("SDL video up (driver: %s)\n", SDL_GetCurrentVideoDriver());
    std::fflush(stdout);

    // AppKit owns the window, so make it here. The context is created with it and
    // released so the engine thread can adopt it - a GL context is current on one
    // thread at a time, and the engine thread is the one that draws.
    if (!posix_gl::CreateWindow(kWindowW, kWindowH)) {
        std::fprintf(stderr, "could not create the window\n");
        return EXIT_FAILURE;
    }
#if defined(__APPLE__) && defined(KISAK_SPARKLE_UPDATER)
    posix_updater::Initialize();
#endif

    pthread_t engine;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16u * 1024u * 1024u);  // the engine recurses deeply
    if (pthread_create(&engine, &attr, engine_thread, nullptr) != 0) {
        std::fprintf(stderr, "could not start the engine thread\n");
        return EXIT_FAILURE;
    }
    pthread_attr_destroy(&attr);
    std::printf("engine running on a secondary thread; main thread is the Cocoa event loop\n");
    std::fflush(stdout);

    // Nothing but Cocoa from here. Waiting runs NSApp's event loop, which is what
    // actually drains the main dispatch queue and lets the engine's GL calls complete.
    const auto handle = [](const SDL_Event &ev) {
        if (ev.type == SDL_QUIT) {
            std::printf("quit requested\n");
            SDL_Quit();
            _exit(0);
        }
        // Escape belongs to the game - it backs out of menus - so it goes to the
        // engine like any other key. Cmd-Q and the close button still quit.
        posix_input::QueueSdlEvent(ev);
    };

    for (;;) {
        SDL_Event ev;

        // SDL_WaitEventTimeout REMOVES the event it returns, so it has to be handled.
        // Discarding it dropped roughly every other input: clicks went missing, and
        // the cursor only tracked while a button was held - motion events flood in
        // then, so enough survived to look like it was working.
        if (SDL_WaitEventTimeout(&ev, 4))
            handle(ev);

        while (SDL_PollEvent(&ev))
            handle(ev);

        posix_input::UpdateMainThread();
    }
}
