#include "posix_input.h"

#include "qcommon/qcommon.h"
#include "ui/keycodes.h"
#include "win32/win_local.h"

#include <SDL.h>

#include <atomic>
#include <cstring>
#include <deque>
#include <mutex>

namespace posix_input {
namespace {

std::mutex g_lock;
std::deque<sysEvent_t> g_queue;

std::atomic<int> g_cursorX{0};
std::atomic<int> g_cursorY{0};
std::atomic<int> g_motionX{0};
std::atomic<int> g_motionY{0};
std::atomic<bool> g_relativeRequested{false};
bool g_relativeApplied = false;
bool g_windowFocused = true;

// The engine's key numbers are ASCII below K_END_ASCII_CHARS and its own above, so
// only the non-ASCII keys need translating.
int KeyNumForKeycode(const SDL_Keycode key)
{
    switch (key)
    {
    case SDLK_TAB:       return K_TAB;
    case SDLK_RETURN:
    case SDLK_KP_ENTER:  return K_ENTER;
    case SDLK_ESCAPE:    return K_ESCAPE;
    case SDLK_SPACE:     return K_SPACE;
    case SDLK_BACKSPACE: return K_BACKSPACE;
    case SDLK_UP:        return K_UPARROW;
    case SDLK_DOWN:      return K_DOWNARROW;
    case SDLK_LEFT:      return K_LEFTARROW;
    case SDLK_RIGHT:     return K_RIGHTARROW;
    case SDLK_LALT:
    case SDLK_RALT:      return K_ALT;
    case SDLK_LCTRL:
    case SDLK_RCTRL:     return K_CTRL;
    case SDLK_LSHIFT:
    case SDLK_RSHIFT:    return K_SHIFT;
    case SDLK_INSERT:    return K_INS;
    case SDLK_DELETE:    return K_DEL;
    case SDLK_PAGEDOWN:  return K_PGDN;
    case SDLK_PAGEUP:    return K_PGUP;
    case SDLK_HOME:      return K_HOME;
    case SDLK_END:       return K_END;
    case SDLK_CAPSLOCK:  return K_CAPSLOCK;
    case SDLK_PAUSE:     return K_PAUSE;
    default: break;
    }

    if (key >= SDLK_F1 && key <= SDLK_F12)
        return K_F1 + (key - SDLK_F1);

    // Printable ASCII is its own key number; Key_Event lowercases.
    if (key > 0 && key < K_END_ASCII_CHARS)
        return key;

    return 0;
}

int KeyNumForMouseButton(const Uint8 button)
{
    switch (button)
    {
    case SDL_BUTTON_LEFT:   return K_MOUSE1;
    case SDL_BUTTON_RIGHT:  return K_MOUSE2;
    case SDL_BUTTON_MIDDLE: return K_MOUSE3;
    default: break;
    }
    return 0;
}

void Push(const sysEventType_t type, const int value, const int value2)
{
    sysEvent_t event{};
    event.evTime = static_cast<int>(SDL_GetTicks());
    event.evType = type;
    event.evValue = value;
    event.evValue2 = value2;

    const std::lock_guard<std::mutex> held(g_lock);
    // If the engine ever stops draining, drop the oldest rather than grow forever.
    if (g_queue.size() > 256)
        g_queue.pop_front();
    g_queue.push_back(event);
}

} // namespace

void QueueSdlEvent(const SDL_Event &event)
{
    switch (event.type)
    {
    case SDL_KEYDOWN:
    case SDL_KEYUP:
    {
        const int keyNum = KeyNumForKeycode(event.key.keysym.sym);
        if (keyNum)
            Push(SE_KEY, keyNum, event.type == SDL_KEYDOWN);

        // SDL text input deliberately excludes editing keys.  CoD4's menu text
        // fields, however, consume Backspace through the character-event path
        // (the same way the Win32 message pump delivered ASCII 8), while the
        // console and bindings still need the regular key event above.
        if (event.type == SDL_KEYDOWN && event.key.keysym.sym == SDLK_BACKSPACE)
            Push(SE_CHAR, '\b', 0);
        break;
    }

    case SDL_TEXTINPUT:
        // One SE_CHAR per byte. The engine's text fields take a character at a time
        // and the menus are ASCII, so anything multi-byte would be rejected anyway.
        for (const char *c = event.text.text; *c; ++c)
            Push(SE_CHAR, static_cast<unsigned char>(*c), 0);
        break;

    case SDL_MOUSEMOTION:
        g_cursorX.store(event.motion.x, std::memory_order_relaxed);
        g_cursorY.store(event.motion.y, std::memory_order_relaxed);
        g_motionX.fetch_add(event.motion.xrel, std::memory_order_relaxed);
        g_motionY.fetch_add(event.motion.yrel, std::memory_order_relaxed);
        break;

    case SDL_MOUSEBUTTONDOWN:
    case SDL_MOUSEBUTTONUP:
    {
        g_cursorX.store(event.button.x, std::memory_order_relaxed);
        g_cursorY.store(event.button.y, std::memory_order_relaxed);
        const int keyNum = KeyNumForMouseButton(event.button.button);
        if (keyNum)
            Push(SE_KEY, keyNum, event.type == SDL_MOUSEBUTTONDOWN);
        break;
    }

    case SDL_MOUSEWHEEL:
    {
        if (event.wheel.y == 0)
            break;
        // A notch is a press and a release; the engine has no wheel axis.
        const int keyNum = event.wheel.y > 0 ? K_MWHEELUP : K_MWHEELDOWN;
        Push(SE_KEY, keyNum, 1);
        Push(SE_KEY, keyNum, 0);
        break;
    }

    case SDL_WINDOWEVENT:
        if (event.window.event == SDL_WINDOWEVENT_FOCUS_GAINED)
            g_windowFocused = true;
        else if (event.window.event == SDL_WINDOWEVENT_FOCUS_LOST)
            g_windowFocused = false;
        break;

    default:
        break;
    }
}

bool NextEvent(sysEvent_t *out)
{
    // Clear here rather than at the call site: posix_backbone_stubs.cpp cannot see
    // the full sysEvent_t without pulling in win_local.h, whose declarations collide
    // with the stubs in that file.
    std::memset(out, 0, sizeof(*out));

    const std::lock_guard<std::mutex> held(g_lock);
    if (g_queue.empty())
        return false;

    *out = g_queue.front();
    g_queue.pop_front();
    return true;
}

void InjectKey(const int keyNum, const bool down)
{
    Push(SE_KEY, keyNum, down ? 1 : 0);
}

void InjectChar(const int character)
{
    Push(SE_CHAR, character, 0);
}

void InjectCursor(const int x, const int y)
{
    g_cursorX.store(x, std::memory_order_relaxed);
    g_cursorY.store(y, std::memory_order_relaxed);
}

void InjectMotion(const int dx, const int dy)
{
    g_motionX.fetch_add(dx, std::memory_order_relaxed);
    g_motionY.fetch_add(dy, std::memory_order_relaxed);
}

void CursorPosition(int *x, int *y)
{
    if (x)
        *x = g_cursorX.load(std::memory_order_relaxed);
    if (y)
        *y = g_cursorY.load(std::memory_order_relaxed);
}

void ConsumeMotion(int *dx, int *dy)
{
    if (dx)
        *dx = g_motionX.exchange(0, std::memory_order_acq_rel);
    if (dy)
        *dy = g_motionY.exchange(0, std::memory_order_acq_rel);
}

void RequestRelativeMode(const bool enabled)
{
    g_relativeRequested.store(enabled, std::memory_order_release);
}

void UpdateMainThread()
{
    const bool wanted = g_windowFocused
        && g_relativeRequested.load(std::memory_order_acquire);
    if (wanted == g_relativeApplied)
        return;

    if (SDL_SetRelativeMouseMode(wanted ? SDL_TRUE : SDL_FALSE) == 0)
    {
        g_relativeApplied = wanted;
        SDL_ShowCursor(wanted ? SDL_DISABLE : SDL_ENABLE);
        // Never feed the synthetic warp/restore delta into the camera.
        g_motionX.store(0, std::memory_order_relaxed);
        g_motionY.store(0, std::memory_order_relaxed);
    }
}

} // namespace posix_input
