#include <atomic>
#include <cstdint>

namespace
{
    // MSVCRT initializes the process-global rand state to one. A CAS keeps the
    // shared sequence well-defined when client FX and other engine work happen
    // on different native threads.
    std::atomic<uint32_t> g_randState{1u};
}

extern "C" void kisak_msvcrt_srand(const unsigned int seed)
{
    g_randState.store(seed, std::memory_order_relaxed);
}

extern "C" int kisak_msvcrt_rand()
{
    uint32_t oldState = g_randState.load(std::memory_order_relaxed);
    uint32_t newState;
    do
    {
        newState = oldState * 214013u + 2531011u;
    } while (!g_randState.compare_exchange_weak(
        oldState, newState, std::memory_order_relaxed, std::memory_order_relaxed));
    return static_cast<int>((newState >> 16u) & 0x7fffu);
}
