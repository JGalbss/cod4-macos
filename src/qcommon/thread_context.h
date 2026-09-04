#pragma once

// ThreadContext_t enum extracted from gfx_d3d/rb_backend.h so it can be
// included on POSIX/Switch without pulling <d3d9.h>. rb_backend.h checks
// the KISAK_THREAD_CONTEXT_T_DEFINED guard below to avoid redefining the
// enum when both headers are pulled transitively (common.cpp includes
// qcommon/threads.h AND gfx_d3d/r_init.h which transitively pulls
// rb_backend.h).

#ifndef KISAK_THREAD_CONTEXT_T_DEFINED
#define KISAK_THREAD_CONTEXT_T_DEFINED

#ifdef KISAK_MP
enum ThreadContext_t : __int32
{
    THREAD_CONTEXT_MAIN         = 0x0,
    THREAD_CONTEXT_BACKEND      = 0x1,
    THREAD_CONTEXT_WORKER0      = 0x2,
    THREAD_CONTEXT_WORKER1      = 0x3,
    THREAD_CONTEXT_TRACE_COUNT  = 0x4,
    THREAD_CONTEXT_TRACE_LAST   = 0x3,
    THREAD_CONTEXT_CINEMATIC    = 0x4,
    THREAD_CONTEXT_TITLE_SERVER = 0x5,
    THREAD_CONTEXT_DATABASE     = 0x6,
    THREAD_CONTEXT_COUNT        = 0x7,
};
#elif defined(KISAK_SP)
enum ThreadContext_t : __int32
{
    THREAD_CONTEXT_MAIN                    = 0x0,
    THREAD_CONTEXT_BACKEND                 = 0x1,
    THREAD_CONTEXT_WORKER0                 = 0x2,
    THREAD_CONTEXT_WORKER1                 = 0x3,
    THREAD_CONTEXT_WORKER2                 = 0x4,
    THREAD_CONTEXT_SERVER                  = 0x5,
    THREAD_CONTEXT_TRACE_COUNT             = 0x6,
    THREAD_CONTEXT_TRACE_LAST              = 0x5,
    THREAD_CONTEXT_CINEMATIC               = 0x6,
    THREAD_CONTEXT_TITLE_SERVER            = 0x7,
    THREAD_CONTEXT_DATABASE                = 0x8,
    THREAD_CONTEXT_STREAM                  = 0x9,
    THREAD_CONTEXT_SNDSTREAMPACKETCALLBACK = 10,
    THREAD_CONTEXT_SERVER_DEMO             = 11,
    THREAD_CONTEXT_COUNT                   = 12,
};
#endif

#endif // KISAK_THREAD_CONTEXT_T_DEFINED
