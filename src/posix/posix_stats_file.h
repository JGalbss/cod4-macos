#pragma once

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <unistd.h>

namespace posix_stats
{
// Never truncate the last good profile. A failed write/flush/rename leaves it
// intact; the caller keeps the in-memory stats dirty and retries later.
inline bool WriteAtomic(const char *path, const void *bytes, size_t size)
{
    std::string temporary = std::string(path) + ".tmp.XXXXXX";
    const int fd = mkstemp(&temporary[0]);
    if (fd < 0)
        return false;
    FILE *file = fdopen(fd, "wb");
    bool saved = false;
    if (file)
    {
        saved = fwrite(bytes, 1, size, file) == size;
        if (fflush(file) != 0 || fsync(fd) != 0)
            saved = false;
        if (fclose(file) != 0)
            saved = false;
        if (saved)
            saved = rename(temporary.c_str(), path) == 0;
    }
    else
        close(fd);
    const int error = errno;
    if (!saved)
        unlink(temporary.c_str());
    errno = error;
    return saved;
}
}
