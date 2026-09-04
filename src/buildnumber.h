// buildnumber.h -- generated on the Windows build by scripts/extern/increment_build.cmake,
// which the posix target does not run. A fixed number is fine: getBuildNumber() only stamps
// the console banner and the UI's version string, and a constant keeps builds reproducible.
#pragma once

#define BUILD_NUMBER 13620   // the original CoD4 build, per the comment in buildnumber.cpp

char *__cdecl getBuildNumber();
int   __cdecl getBuildNumberAsInt();
