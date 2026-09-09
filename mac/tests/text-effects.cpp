#include "posix/posix_text_effects.h"

#include <cassert>
#include <climits>
#include <cmath>
#include <cstdio>

int main()
{
    using posix_text::EvaluateEffect;
    const auto at = [](int time) {
        return EvaluateEffect(0xc0, 20, time, 1000, 30, 2500, 1000);
    };
    assert(at(1000).maxChars == 1 && at(1000).alpha == 1.0f);
    assert(at(1300).maxChars == 11);
    assert(at(2000).maxChars == 20 && at(2000).alpha == 1.0f);
    assert(at(3500).alpha == 1.0f);
    assert(std::fabs(at(4000).alpha - 0.5f) < 0.0001f);
    assert(at(4499).alpha > 0.0f);
    assert(at(4500).maxChars == 0 && at(4500).alpha == 0.0f);
    assert(at(60000).alpha == 0.0f); // HUD element still exists in later snapshots.
    assert(at(500).alpha == 1.0f); // Future birth/rewound demo clamps safely.
    assert(at(2000).alpha == 1.0f); // Rewind after expiry replays the effect.
    assert(EvaluateEffect(0xc0, 20, 60100, 60000, 30, 2500, 1000).alpha == 1.0f);
    assert(EvaluateEffect(0, 20, 60000, 1000, 30, 2500, 1000).alpha == 1.0f);
    assert(EvaluateEffect(0x80, 20, 60000, 1000, 30, 2500, 1000).maxChars == 20);
    assert(EvaluateEffect(0xc0, 20, 3500, 1000, 0, 2500, 0).alpha == 0.0f);
    assert(EvaluateEffect(0xc0, 20, INT_MAX, 1, 0, INT_MAX, INT_MAX).alpha == 1.0f);
    assert(EvaluateEffect(0xc0, 20, INT_MAX, INT_MIN, 0, 2500, 1000).alpha == 0.0f);
    assert(EvaluateEffect(0xc0, 0, 1000, 1000, 0, 2500, 1000).maxChars == 0);
    std::puts("ok: timed HUD reveal, fade, expiry, replay, re-arm and persistent labels");
}
