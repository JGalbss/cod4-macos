// Stub do MyAssertHandler usado pelas macros iassert/vassert e por chamadas
// diretas em varios arquivos de src/universal/. No upstream Windows isso vai
// pra um dialog box + clipboard + breakpoint; aqui imprimimos no stderr e
// abortamos (comportamento aceitavel pra builds POSIX/Switch durante o porte).
//
// Quando integrarmos o renderer e tivermos uma overlay de debug, MyAssertHandler
// pode ser refeito pra mostrar a mensagem no jogo em vez de matar o processo.

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#ifdef __SWITCH__
#include <switch.h>
#endif

void MyAssertHandler(const char *filename, int line, int /*type*/, const char *fmt, ...)
{
    char buf[1024];
    int n = std::snprintf(buf, sizeof(buf), "[assert] %s:%d ",
                          filename ? filename : "(null)", line);
    if (fmt && n < (int)sizeof(buf))
    {
        std::va_list ap;
        va_start(ap, fmt);
        std::vsnprintf(buf + n, sizeof(buf) - n, fmt, ap);
        va_end(ap);
    }
    std::fputs(buf, stderr);
    std::fputc('\n', stderr);
#ifdef __SWITCH__
    svcOutputDebugString(buf, std::strlen(buf));
#endif
    std::abort();
}
