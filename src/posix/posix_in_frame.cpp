// Feed the same absolute + relative tuple the Win32 DirectInput path supplied.
// CL_MouseEvent decides whether that frame belongs to the UI or to camera control.
#include "posix/posix_gl_present.h"
#include "posix/posix_input.h"

#include "client_mp/client_mp.h"

void IN_Frame()
{
    if (!posix_gl::HasWindow())
        return;

    int x = 0;
    int y = 0;
    int dx = 0;
    int dy = 0;
    posix_input::CursorPosition(&x, &y);
    posix_input::ConsumeMotion(&dx, &dy);
    const bool captured = CL_MouseEvent(x, y, dx, dy) != 0;
    posix_input::RequestRelativeMode(captured);
}
