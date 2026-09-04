#include "database.h"

#include <zlib/zlib.h>
#include <qcommon/qcommon.h>

// Note: On XBox it seems to use tomcrypt, and is more involved. 

int32_t __cdecl DB_AuthLoad_InflateInit(z_stream_s *stream, bool isSecure)
{
    iassert(!isSecure);
    // The hard-coded "1.1.4" is a decompilation artifact from the bundled zlib. POSIX builds
    // link the system zlib (1.2.12 on macOS); inflateInit_ compares only the major digit so
    // it happened to pass, but passing the header's own ZLIB_VERSION is what the inflateInit
    // macro does and keeps the size check honest.
    int rc = inflateInit_(stream, ZLIB_VERSION, sizeof(z_stream));
    Com_Printf(16, "[zlib] inflateInit_ -> %d (version %s, sizeof(z_stream)=%zu)\n",
               rc, ZLIB_VERSION, sizeof(z_stream));
    return rc;
}

void __cdecl DB_AuthLoad_InflateEnd(z_stream_s *stream)
{
    inflateEnd(stream);
}

uint32_t __cdecl DB_AuthLoad_Inflate(z_stream_s *stream, int32_t flush)
{
    uInt in0 = stream->avail_in, out0 = stream->avail_out;
    uint32_t rc = (uint32_t)inflate(stream, flush);
    if (rc) Com_Printf(16, "[zlib] inflate -> %u  (in %u->%u, out %u->%u, msg=%s)\n",
                       rc, in0, stream->avail_in, out0, stream->avail_out,
                       stream->msg ? stream->msg : "(none)");
    return rc;
}

