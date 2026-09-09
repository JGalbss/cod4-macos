#pragma once

#include <algorithm>
#include <cstdint>

namespace posix_text {

struct EffectState
{
    int maxChars;
    float alpha;
};

// Script HUD elements can remain in snapshots after their pulse effect ends.
// As in RB_DrawText2D, their render command's lifetime, not the element's
// existence, decides whether text is visible. Use scene/game time, never wall
// time, so pause, demos and killcam playback retain the right timing.
inline EffectState EvaluateEffect(unsigned int renderFlags, int maxChars,
                                 int sceneTime, int birthTime, int letterTime,
                                 int decayStartTime, int decayDuration)
{
    EffectState state{std::max(0, maxChars), 1.0f};
    if (!(renderFlags & 0x40))
        return state; // Persistent labels have no pulse deadline.

    const int64_t elapsed = std::max<int64_t>(0, int64_t(sceneTime) - birthTime);
    const int64_t decayStart = std::max(0, decayStartTime);
    const int64_t duration = std::max(0, decayDuration);
    if (elapsed >= decayStart + duration)
        return {0, 0.0f};

    if (letterTime > 0)
        state.maxChars = static_cast<int>(std::min<int64_t>(
            state.maxChars, elapsed / letterTime + 1));
    if (elapsed > decayStart && duration > 0)
        state.alpha = 1.0f - static_cast<float>(elapsed - decayStart) / duration;
    return state;
}

} // namespace posix_text
