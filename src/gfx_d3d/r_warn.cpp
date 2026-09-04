#include "r_debug.h"
#include "r_init.h"

const dvar_s *r_warningRepeatDelay;
unsigned int s_warnCount[41];


// KISAKHACK: va_start with a fixed-size enum argument triggers -Wvarargs
// on clang (it's spec-UB for promotable types). Forward through an int-
// parameterized helper so the va_start sees an int argument.
static void R_WarnOncePerFrameV(int warnType, va_list va)
{
    char message[1028];
    float frameRate;

    iassert( r_warningRepeatDelay );
    frameRate = R_UpdateFrameRate();
    if (s_warnCount[warnType] < rg.frontEndFrameCount)
    {
        s_warnCount[warnType] = rg.frontEndFrameCount + (int)(frameRate * r_warningRepeatDelay->current.value);
        _vsnprintf(message, 0x400u, s_warnFormat[warnType], va);
        Com_PrintWarning(8, "%s", message);
    }
}

void R_WarnOncePerFrame(int warnType, ...)
{
    va_list va;
    va_start(va, warnType);
    R_WarnOncePerFrameV(warnType, va);
    va_end(va);
}

unsigned int frameCount;
int previous_0;
float frameRate;
double __cdecl R_UpdateFrameRate()
{
    int frameTime; // [esp+0h] [ebp-8h]
    unsigned int current; // [esp+4h] [ebp-4h]

    if (frameCount != rg.frontEndFrameCount)
    {
        if (frameCount)
        {
            if (frameCount + 1 == rg.frontEndFrameCount)
            {
                current = Sys_Milliseconds();
                frameTime = current - previous_0;
                previous_0 = current;
                if (!frameTime)
                    frameTime = 1;
                if (frameTime >= 0)
                    frameRate = 1000.0 / (double)frameTime;
                else
                    frameRate = 0.0;
            }
            else
            {
                frameRate = 0.0;
            }
        }
        else
        {
            previous_0 = Sys_Milliseconds();
        }
        frameCount = rg.frontEndFrameCount;
    }
    return frameRate;
}

void __cdecl R_WarnInitDvars()
{
    DvarLimits min; // [esp+4h] [ebp-10h]

    min.value.max = 30.0;
    min.value.min = 0.0;
    r_warningRepeatDelay = Dvar_RegisterFloat(
        "r_warningRepeatDelay",
        5.0,
        min,
        DVAR_NOFLAG,
        "Number of seconds after displaying a \"per-frame\" warning before it will display again");
}

