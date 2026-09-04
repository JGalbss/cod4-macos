// Keyboard and mouse for the POSIX build.
//
// SDL delivers events only on the OS main thread, but the engine consumes them from
// Com_EventLoop on the engine thread, so they cross between the two through a small
// locked queue.
#pragma once

union SDL_Event;
struct sysEvent_t;

namespace posix_input {

// Main thread. Translates one SDL event and queues whatever the engine understands.
void QueueSdlEvent(const SDL_Event &event);

// Engine thread. Fills `out` and returns true, or returns false when the queue is
// empty - Com_EventLoop reads that as SE_NONE and stops for this frame.
bool NextEvent(sysEvent_t *out);

// Engine thread. Where the OS cursor is, in window pixels.
void CursorPosition(int *x, int *y);

// Engine thread: take all SDL relative motion received since the previous frame.
void ConsumeMotion(int *dx, int *dy);

// Engine thread requests gameplay capture; the main Cocoa/SDL thread applies it.
void RequestRelativeMode(bool enabled);

// Main thread. Applies a pending relative-mode request where AppKit permits it.
void UpdateMainThread();

// Test harness: queue a keystroke or a character as if it came from SDL. Lets the
// menu path be driven without a human at the keyboard.
void InjectKey(int keyNum, bool down);
void InjectChar(int character);
void InjectCursor(int x, int y);
void InjectMotion(int dx, int dy);

} // namespace posix_input
