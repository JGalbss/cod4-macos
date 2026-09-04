// Window, GL context and render-command presentation for the POSIX build.
//
// The window is created on the OS main thread because AppKit owns it, but the
// engine runs Com_Frame on a secondary thread and that is where the draw calls
// come from, so the context is created on main, released, and adopted by the
// engine thread once.
#pragma once

#include <cstddef>

struct SDL_Window;

namespace posix_gl {

// Main thread, before the engine thread starts.
bool CreateWindow(int width, int height);

// Engine thread, once, before the first frame.
bool AdoptContext();

// Engine thread. Walks the front end's command list and draws what gfx_gl can
// already express, then presents.
void PresentFrame();

bool HasWindow();

// Refresh rate of the display that owns the native game window.  This is
// queried while the window is created on AppKit's main thread, so callers on
// the engine thread do not have to touch Cocoa.
int DisplayFrequency();

// Engine-thread request and main-thread application for a windowed video-mode
// change. AppKit window mutation must stay on the process main thread.
void RequestWindowSize(int width, int height);
void UpdateWindowMainThread();

// Main-thread macOS helpers used before engine startup. They remember a
// user-selected retail CoD4 data folder and keep writable client data in the
// normal Application Support location instead of modifying the installation.
bool SavedGameDataDirectory(char *path, std::size_t pathSize);
bool SelectGameDataDirectory(char *path, std::size_t pathSize);
bool WritableGameDataDirectory(char *path, std::size_t pathSize);

// The SDL window, which DXVK Native accepts in place of an HWND.
::SDL_Window *Window();

// Write the next presented frame to fs_basepath/screenshots as a PPM. Backs the
// "screenshot" console command, since the D3D screenshot path is not built here.
void RequestFrameDump();

// Window content size in logical points. CoD4's UI and vidConfig operate in
// this coordinate space; DrawableSize below is the Retina pixel resolution.
void WindowSize(int *width, int *height);

// Window size in pixels, for mapping the OS cursor into the UI's 640x480 canvas.
void DrawableSize(int *width, int *height);

} // namespace posix_gl
