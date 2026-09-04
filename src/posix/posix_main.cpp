// Entry point para targets POSIX (macOS/Linux) e Switch (libnx).
//
// Substitui src/win32/win_main.cpp (WinMain) no porte. Por enquanto e um
// driver minimal que exercita os primeiros subsistemas upstream trazidos
// para o build POSIX, servindo como smoke test do pipeline cross-platform.
//
// No Switch (__SWITCH__), inicializa o console do libnx pra que stdout fique
// visivel na tela e fica em appletMainLoop ate o usuario apertar Plus (+).
//
// Ver docs/SWITCH_PORT.md para o estado atual do porte.

#include <cstdio>
#include <cstring>

#include "base64.h"

#ifdef __SWITCH__
#include <switch.h>
#endif

namespace {

void run_smoke_tests()
{
    std::printf("KisakCOD-Switch posix bootstrap (Phase 1 skeleton)\n");

    const char *plain = "KisakCOD";
    unsigned char encoded[64] = {0};
    unsigned int out_len = b64_encode(
        reinterpret_cast<const unsigned char *>(plain),
        static_cast<unsigned int>(std::strlen(plain)),
        encoded);

    std::printf("[smoke] base64('%s') = '%s' (%u bytes)\n",
                plain, encoded, out_len);
}

} // namespace

int main(int /*argc*/, char ** /*argv*/)
{
#ifdef __SWITCH__
    // Console framebuffer do libnx — redireciona stdout pra tela do Switch.
    consoleInit(nullptr);

    // hid (input) precisa ser inicializado pra ler os botoes do controle.
    PadState pad;
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    padInitializeDefault(&pad);

    run_smoke_tests();
    std::printf("\nPress + to exit.\n");
    consoleUpdate(nullptr);

    // appletMainLoop retorna false quando o homebrew menu quer encerrar.
    while (appletMainLoop()) {
        padUpdate(&pad);
        if (padGetButtonsDown(&pad) & HidNpadButton_Plus) {
            break;
        }
        consoleUpdate(nullptr);
    }

    consoleExit(nullptr);
    return 0;
#else
    run_smoke_tests();
    return 0;
#endif
}
