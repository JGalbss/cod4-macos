// Shim that lets upstream `#include <zlib/zlib.h>` resolve to the system
// zlib on POSIX targets (macOS SDK) and to switch-zlib on the Switch
// target. The bundled `deps/zlib/` source/headers are pre-1.2 era and do
// not compile cleanly on modern systems (TARGET_OS_MAC handling guards
// the `Byte` typedef incorrectly).
//
// Used by adding `src/posix/include_shims` to the include path in the
// POSIX and Switch CMakeLists. Upstream code can keep its
// `<zlib/zlib.h>` include verbatim.

#pragma once
#include <zlib.h>
