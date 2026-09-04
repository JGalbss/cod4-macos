#pragma once

#include <cstddef>

// Inline text commands are stored directly in console/message strings.  The
// original Win32 command stored a four-byte Material pointer; native 64-bit
// builds must carry the complete pointer and teach every parser its new size.
constexpr unsigned char CONTXTCMD_TYPE_HUDICON = 1;
constexpr unsigned char CONTXTCMD_TYPE_HUDICON_FLIP = 2;
constexpr std::size_t CONTXTCMD_ARG_HUDICON_MATERIAL = 3;
constexpr std::size_t CONTXTCMD_LEN_HUDICON =
    CONTXTCMD_ARG_HUDICON_MATERIAL + sizeof(void *); // bytes following '^'
constexpr std::size_t CONTXTCMD_TOTAL_HUDICON = CONTXTCMD_LEN_HUDICON + 1;
